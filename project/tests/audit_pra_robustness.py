"""Independent CSV/manifest audit and object-cluster contrasts; no model writes."""
from pathlib import Path
import hashlib
import json
import sys
import numpy as np
import pandas as pd

run = Path(sys.argv[1])
out = Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
assert (run / 'ROBUST_COMPLETE.json').is_file(), 'Robustness job is not complete.'
P = pd.read_csv(run / 'robust_predictions.csv')
S = pd.read_csv(run / 'robust_summary.csv')
spec = json.loads((run / 'spec.json').read_text(encoding='utf-8-sig'))
ids = np.asarray(spec['robust_ids'], dtype=int)
seed_ids = spec['robust_seeds']
N = len(ids)
checks = 0
largest = 0.0

def equal(a, b, text, tol=2e-10):
    global checks, largest
    a, b = np.asarray(a, float), np.asarray(b, float)
    assert np.array_equal(np.isnan(a), np.isnan(b)), f'NaN mismatch: {text}'
    good = np.isfinite(a) & np.isfinite(b)
    d = np.max(np.abs(a[good] - b[good]), initial=0)
    largest = max(largest, float(d))
    assert d <= tol, f'{text}: {d}'
    checks += a.size

def boolean(series):
    values = series.astype(str).str.lower()
    assert values.isin(['0', '1', 'true', 'false']).all()
    return values.isin(['1', 'true']).to_numpy()

bools = ['finite_prediction', 'model_valid', 'accepted', 'raw_positive_mass',
         'bounds_hit', 'physical_success', 'teacher_accepted']
for b in bools:
    P[b] = boolean(P[b])
methods = ['lao_pe_transplant', 'lao_t_transplant', 'lao_ta_transplant',
           'encoder_only', 'encoder_plus_power', 'power_only',
           'physics_residual_nn', 'physics_inverse']
assert set(P.method) == set(methods)
assert len(P) == 280800 and len(S) == 1092
assert set(P.object_id) == set(ids)
assert len(P.condition.unique()) == 12
assert not P.duplicated(['condition', 'perturbation_seed', 'object_id', 'method',
                         'model_seed', 'model_kind', 'postprocessing']).any()
assert P.groupby('object_id')[['true_mass_kg', 'true_cx_m', 'true_cz_m']].nunique().eq(1).all().all()
for c in spec['robust_conditions']:
    expected = set(seed_ids if c['randomized'] else [0])
    assert set(P.loc[P.condition == c['id'], 'perturbation_seed']) == expected

true_cols = ['true_mass_kg', 'true_cx_m', 'true_cz_m']
pred_cols = ['pred_mass_kg', 'pred_cx_m', 'pred_cz_m']
prediction = P[pred_cols].to_numpy()
finite = np.isfinite(prediction).all(axis=1)
assert np.array_equal(P.finite_prediction, finite)
assert np.array_equal(P.accepted, finite & P.model_valid & P.raw_positive_mass & P.physical_success)

group_keys = ['condition', 'perturbation_seed', 'method', 'model_seed', 'model_kind', 'postprocessing']
summary_index = S.set_index(group_keys)
count_fields = ['finite_n', 'model_valid_n', 'accepted_n', 'raw_positive_mass_n',
                'bounds_hit_n', 'physical_success_n']
metric_fields = ['prediction_coverage', 'accepted_coverage', 'bounds_hit_rate',
                 'mass_mae_g', 'cx_mae_mm', 'cz_mae_mm',
                 'mass_rmse_g', 'cx_rmse_mm', 'cz_rmse_mm',
                 'mass_p95_g', 'cx_p95_mm', 'cz_p95_mm',
                 'mass_max_g', 'cx_max_mm', 'cz_max_mm', 'mass_mape_percent',
                 'planar_com_mean_distance_mm', 'planar_com_p95_distance_mm',
                 'accepted_mass_mae_g', 'accepted_cx_mae_mm', 'accepted_cz_mae_mm']
for key, Q in P.groupby(group_keys, sort=False):
    assert len(Q) == N and Q.object_id.nunique() == N
    row = summary_index.loc[key]
    truth = Q[true_cols].to_numpy()
    pred = Q[pred_cols].to_numpy()
    e = abs(pred - truth) * 1000
    good = Q.finite_prediction.to_numpy()
    accepted = Q.accepted.to_numpy()
    values = dict(planned_objects=N, planned_prediction_count=N, replicate_count=1,
                  finite_n=good.sum(), model_valid_n=Q.model_valid.sum(), accepted_n=accepted.sum(),
                  raw_positive_mass_n=Q.raw_positive_mass.sum(), bounds_hit_n=Q.bounds_hit.sum(),
                  physical_success_n=Q.physical_success.sum(), prediction_coverage=good.mean(),
                  accepted_coverage=accepted.mean(), bounds_hit_rate=Q.bounds_hit.mean())
    m = np.full(3, np.nan); rms = m.copy(); p95 = m.copy(); maximum = m.copy(); amae = m.copy()
    mape = dist = dist95 = np.nan
    if good.any():
        m = e[good].mean(axis=0)
        rms = np.sqrt((e[good] ** 2).mean(axis=0))
        p95 = np.quantile(e[good], .95, axis=0, method='hazen')
        maximum = e[good].max(axis=0)
        mape = 100 * (e[good, 0] / (1000 * truth[good, 0])).mean()
        distance = np.linalg.norm((pred[good, 1:] - truth[good, 1:]) * 1000, axis=1)
        dist = distance.mean(); dist95 = np.quantile(distance, .95, method='hazen')
    if accepted.any():
        amae = e[accepted].mean(axis=0)
    for prefix, vals in [('mae', m), ('rmse', rms), ('p95', p95), ('max', maximum)]:
        for j, (part, unit) in enumerate([('mass', 'g'), ('cx', 'mm'), ('cz', 'mm')]):
            values[f'{part}_{prefix}_{unit}'] = vals[j]
    for j, (part, unit) in enumerate([('mass', 'g'), ('cx', 'mm'), ('cz', 'mm')]):
        values[f'accepted_{part}_mae_{unit}'] = amae[j]
    values.update(mass_mape_percent=mape, planar_com_mean_distance_mm=dist,
                  planar_com_p95_distance_mm=dist95)
    for name, value in values.items():
        equal(row[name], value, f'{key}: {name}')

# Equal error-metric averaging across noise replicates, not prediction averaging.
for _, row in S.loc[S.perturbation_seed == -1].iterrows():
    chosen = S.perturbation_seed != -1
    for k in ['condition', 'method', 'model_seed', 'model_kind', 'postprocessing']:
        chosen &= S[k] == row[k]
    Q = S.loc[chosen]
    assert len(Q) == len(seed_ids) == 3
    equal(row.planned_objects, N, 'unique-object denominator')
    equal(row.planned_prediction_count, N * len(Q), 'replicate denominator')
    equal(row.replicate_count, len(Q), 'replicate count')
    for k in count_fields:
        equal(row[k], Q[k].sum(), f'aggregate count {k}')
    for k in metric_fields:
        equal(row[k], np.mean(Q[k].to_numpy()), f'aggregate metric {k}')

# Native clipping per model seed, then legitimate model ensemble averaging.
base_keys = ['condition', 'perturbation_seed', 'object_id', 'method', 'model_seed', 'model_kind']
raw = P.loc[P.postprocessing == 'raw'].set_index(base_keys).sort_index()
clipped = P.loc[P.postprocessing == 'common_clip'].set_index(base_keys).sort_index()
assert raw.index.equals(clipped.index)
seed_rows = raw.index.get_level_values('model_kind') != 'ensemble'
limits = np.array([[.06, .25], [.04, .20], [-.025, .025]])
expected_clip = np.clip(raw.loc[seed_rows, pred_cols].to_numpy(), limits[:, 0], limits[:, 1])
equal(clipped.loc[seed_rows, pred_cols].to_numpy(), expected_clip, 'per-model clipping', tol=1e-12)
ensemble_keys = ['condition', 'perturbation_seed', 'object_id', 'method', 'postprocessing']
individual = P.loc[P.model_kind == 'single'].groupby(ensemble_keys, sort=True)
seed_means = individual[pred_cols].agg(lambda x: np.mean(x.to_numpy()))
E = P.loc[P.model_kind == 'ensemble'].set_index(ensemble_keys).sort_index()
assert seed_means.index.equals(E.index)
equal(E[pred_cols].to_numpy(), seed_means.to_numpy(), 'ensemble averaging', tol=1e-12)
assert np.array_equal(E.bounds_hit.to_numpy(), individual.bounds_hit.any().to_numpy())

# The nominal case must exactly reproduce the completed comparison run.
old = pd.read_csv(Path(spec['lao_dir']) / 'summary.csv').rename(columns={'seed': 'model_seed'})
keys = ['method', 'model_seed', 'model_kind', 'postprocessing']
nominal = S.loc[(S.condition == 'nominal') & (S.perturbation_seed == 0)].set_index(keys).sort_index()
old = old.loc[old.method.isin(methods)].set_index(keys).sort_index()
assert nominal.index.equals(old.index)
for key in ['mass_mae_g', 'cx_mae_mm', 'cz_mae_mm', 'mass_rmse_g', 'cx_rmse_mm', 'cz_rmse_mm',
            'finite_n', 'model_valid_n', 'accepted_n', 'bounds_hit_n', 'prediction_coverage', 'accepted_coverage']:
    equal(nominal[key].to_numpy(), old[key].to_numpy(), f'nominal comparison continuity: {key}')

# All source and locked model files remain byte-identical.
def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

hash_count = 0
for manifest in ['source_manifest.csv', 'input_manifest.csv', 'robust_input_manifest.csv']:
    M = pd.read_csv(run / manifest)
    for _, item in M.iterrows():
        if 'relative_path' in M:
            path = run / 'source_snapshot' / item.relative_path
        elif 'path' in M:
            path = Path(item.path)
        else:
            path = Path(item.input_path)
        assert digest(path) == item.sha256, f'Hash changed: {path}'
        hash_count += 1

# Paired contrasts: noise realizations are collapsed as errors within object.
# Bootstrap resamples objects, retaining their full replicate block.
Q = P.loc[(P.model_kind != 'single') & (P.postprocessing == 'common_clip')].copy()
err = abs(Q[pred_cols].to_numpy() - Q[true_cols].to_numpy()) * 1000
for j, name in enumerate(['mass_error_g', 'cx_error_mm', 'cz_error_mm']):
    Q[name] = err[:, j]
error_cols = ['mass_error_g', 'cx_error_mm', 'cz_error_mm']
cluster = Q.groupby(['condition', 'method', 'object_id'], sort=True)[error_cols].agg(lambda x: np.mean(x.to_numpy()))
rng = np.random.default_rng(920030)
contrasts = []
for condition in Q.condition.unique():
    main = cluster.loc[(condition, 'physics_residual_nn')].sort_index()
    for baseline in ['physics_inverse', 'encoder_plus_power', 'power_only', 'lao_ta_transplant']:
        reference = cluster.loc[(condition, baseline)].sort_index()
        assert main.index.equals(reference.index)
        delta = reference.to_numpy() - main.to_numpy()
        finite = np.isfinite(delta).all(axis=1)
        d = delta[finite]
        if len(d) > 1:
            draw = rng.integers(0, len(d), (2000, len(d)))
            boot = d[draw].mean(axis=1)
            ci = np.quantile(boot, [.025, .975], axis=0)
            mean = d.mean(axis=0)
        else:
            ci = np.full((2, 3), np.nan); mean = np.full(3, np.nan)
        for j, parameter in enumerate(['mass_g', 'cx_mm', 'cz_mm']):
            contrasts.append(dict(condition=condition, baseline=baseline, reference='physics_residual_nn',
                                  parameter=parameter, mean_error_reduction=mean[j], lower95=ci[0, j], upper95=ci[1, j],
                                  paired_objects=len(d), planned_objects=N, bootstrap_n=2000,
                                  scope='Error averaged within object across noise replicates; paired object bootstrap; frozen models; no multiplicity correction.'))
pd.DataFrame(contrasts).to_csv(out / 'paired_object_bootstrap.csv', index=False)
selected = S.loc[(S.model_kind != 'single') & (S.postprocessing == 'common_clip')]
selected = selected.loc[(selected.perturbation_seed == -1) | (selected.perturbation_seed == 0)]
selected.to_csv(out / 'main_results.csv', index=False)
report = dict(passed=True, scalar_metric_checks=checks, max_abs_numeric_difference=largest,
              manifest_hash_checks=hash_count, prediction_rows=len(P), summary_rows=len(S),
              independent_objects=N, repeated_object_condition_cases=5400,
              paired_contrast_rows=len(contrasts), paired_unit='object, with all perturbation replicates retained')
(out / 'AUDIT_PASS.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
main = selected.loc[selected.method == 'physics_residual_nn']
print(main[['condition', 'mass_mae_g', 'cx_mae_mm', 'cz_mae_mm', 'accepted_coverage', 'bounds_hit_rate']].to_string(index=False))
