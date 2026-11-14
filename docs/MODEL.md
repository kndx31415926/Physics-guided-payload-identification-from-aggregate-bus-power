# Payload power models and estimation

This document specifies the observation model, its identifiability conditions,
the simulation configurations, and the estimators implemented in this project.
All quantities use SI units unless a different unit is stated. Vectors of
drive parameters follow yaw–pitch–pitch–pitch joint order; vectors of link
parameters follow the three pitch links.

## 1. Static observation model

Consider a rigid payload under vertical gravity, with no external contact.
At pose $k$, the available summaries are joint configuration $q_k$, mean
holding power $\bar P_k$, and within-window power standard deviation $s_{P,k}$.
At rest, mechanical output power approaches zero, but active drives may still
consume power to balance gravity. A calibrated quadratic holding-loss model
represents this consumption. Its coefficients are effective drive-loss
coefficients, not measured winding resistances. Brakes, self-locking drives,
static friction, or varying auxiliary consumption can invalidate the model.

Define payload parameters and mass moments as

$$
\theta=(m,c_x,c_z)^{\mathsf T},\qquad
\beta=(m,h_x,h_z)^{\mathsf T}=(m,mc_x,mc_z)^{\mathsf T}.
$$

The static torque and power maps are

$$
\tau_k(\beta)=g_{0k}+Y_k\beta,
\qquad
\bar P_k=F_k(\beta;\eta)+\epsilon_k,
\qquad
F_k(\beta;\eta)=a+\tau_k(\beta)^{\mathsf T}D\tau_k(\beta).
$$

Here $g_{0k}$ is empty-arm gravity torque,
$D=\operatorname{diag}(h_1,h_2,h_3,h_4)$ contains nonnegative holding-loss
coefficients, $a$ is auxiliary draw, and $\eta$ denotes the calibration.
The indexed electrical coefficients $h_i$ are distinct from mass moments
$h_x,h_z$. For pitch-link lengths $L_j$, cumulative pitch
$\alpha_{kj}=\sum_{\ell=1}^j q_{k,\ell+1}$, and tool pitch
$\phi_k=\alpha_{k3}$, the frame convention gives

$$
[Y_k]_{1,:}=0,\qquad
[Y_k]_{j+1,:}=-g\left[
\sum_{r=j}^{3}L_r\cos\alpha_{kr},\ \cos\phi_k,\ \sin\phi_k
\right],\qquad j=1,2,3.
$$

The transverse COM coordinate $c_y$ is parallel to the pitch axes and absent
from gravitational potential. Static observations also contain no yaw gravity
torque or velocity-dependent electrical terms. Thus these observations target
mass and planar COM, not the full three-dimensional COM.

### Sensitivities and identifiability

Stack the pose predictions into $F$. The Jacobians satisfy

$$
[J_\beta]_{k,:}=2\tau_k^{\mathsf T}DY_k,\qquad
J_\theta=J_\beta T(\theta),\qquad
T(\theta)=\begin{bmatrix}1&0&0\\c_x&m&0\\c_z&0&m\end{bmatrix}.
$$

Because $\det T=m^2$, the parameterizations have equal local rank when $m>0$.
Full column rank is sufficient for local identification [1]. Repeating a pose
or changing only yaw adds no independent static information. At constant tool
pitch $\phi$, moments enter only through $h_x\cos\phi+h_z\sin\phi$, leaving
an exact ambiguity along $(0,\sin\phi,-\cos\phi)^{\mathsf T}$.

For positive mass bounds, a physical parameter box maps to the convex domain

$$
\Omega=\left\{(m,h_x,h_z):
\begin{aligned}
m_{\min}&\leq m\leq m_{\max},\\
c_{x,\min}m&\leq h_x\leq c_{x,\max}m,\\
c_{z,\min}m&\leq h_z\leq c_{z,\max}m
\end{aligned}\right\}.
$$

Each map is a squared affine norm:
$F_k-a=\|D^{1/2}(g_{0k}+Y_k\beta)\|_2^2$. The quadratic midpoint argument
also occurs in affine phase retrieval [2].

**Conditional injectivity.** Fix the postures, empty-arm model, and electrical
calibration. If $\operatorname{rank}J_\beta(\beta)=3$ throughout $\Omega$,
then $F$ is injective on $\Omega$. If a fixed positive diagonal matrix $S$
and constant $\kappa>0$ satisfy
$\sigma_{\min}(J_\beta(\beta)S)\geq\kappa$ throughout $\Omega$, then

$$
\|F(\beta_1)-F(\beta_2)\|_2
\geq\kappa\|S^{-1}(\beta_1-\beta_2)\|_2.
$$

**Proof.** Each component of $F$ is quadratic, so

$$
F(\beta_1)-F(\beta_2)=
J_\beta\!\left(\frac{\beta_1+\beta_2}{2}\right)(\beta_1-\beta_2).
$$

Convexity places the midpoint in $\Omega$. Full column rank makes the output
difference zero only when $\beta_1=\beta_2$. Positive mass then determines
$c_x=h_x/m$ and $c_z=h_z/m$. Substitute
$\beta_1-\beta_2=S S^{-1}(\beta_1-\beta_2)$ into this identity and apply the
minimum singular-value bound to obtain the stability inequality.

This statement concerns noiseless outputs at fixed poses and calibration.
Uniqueness and convergence of a noisy least-squares solver require separate
analysis.

### Domain bounds

To assess rank between grid points, partition the physical solver box into
sub-boxes and enclose their mass-moment ranges. Since $J_\beta$ is affine,
$G_j=\partial J_\beta/\partial\beta_j$ is constant. At a box center $b$ with
half-widths $r_j$, the singular-value perturbation bound [3] yields

$$
\ell=\sigma_{\min}(J_\beta(b)S)
-(1+\varepsilon_G)\sum_j r_j\|G_jS\|_2-\delta,
$$

$$
\delta=\varepsilon_{\mathrm{cover}}\max\!\left\{
1,\|J_\beta(b)S\|_2+
(1+\varepsilon_G)\sum_jr_j\|G_jS\|_2\right\}.
$$

Numerical safeguards are $\varepsilon_G=10^{-12}$ and
$\varepsilon_{\mathrm{cover}}=10^{-10}$. The diagonal entries of $S$ are
the enclosing domain spans: $0.19$ kg, $0.0476$ kg m, and $0.0125$ kg m.
The unit floor applies in these scaled coordinates. Bisection resolves all
boxes. The six-pose configuration has 17,797 leaves and minimum bound
$1.59647\times10^{-5}$; the eight-pose configuration has 3,327 leaves and
minimum bound $1.60902\times10^{-5}$. Different partitions mean these loose
bounds do not rank the configurations' statistical precision. Evaluation uses
double precision without directed outward rounding; it supports the rank
condition numerically but is not a formal rounding-error certificate.

Across an $11^3$ payload grid, repeated-pose, constant-tool-pitch, and varying-
pitch configurations have ranks one, two, and three, respectively. The
eight-pose inverse recovers the noiseless solution in all 675 solves over
27 objects and 25 initializations. Independently calculated torques agree
with MATLAB `rigidBodyTree` within $6.67\times10^{-16}$ N m. These checks
use fixed poses and nominal calibration. Rank at achieved postures under
plant mismatch must be evaluated separately.

### Calibration ambiguity

For electrical parameters $\eta_s=(a,h_2,h_3,h_4)^{\mathsf T}$, the
sensitivity row is $H_k=[1,\tau_{k2}^2,\tau_{k3}^2,\tau_{k4}^2]$.
Estimating these nuisance parameters reduces the information available for
payload parameters [4]. Full rank of $J_\theta$ alone does not separate
payload changes from calibration error. Empty-arm recalibration below fits
auxiliary draw and one common holding-loss scale; it does not represent
independent changes in every motor loss. Known nonzero loads add distinct
torque patterns. Their mass and COM must be known in the attachment frame
under the operating conditions used for unknown loads.

If the empty-arm gravity scale is also uncertain, the transformation

$$
g_{0k}'=s g_{0k},\qquad m'=s m,\qquad
(c_x',c_z')=(c_x,c_z),\qquad D'=D/s^2,\qquad a'=a
$$

preserves unknown-load and empty-arm predictions for any $s>0$. A known
nonzero reference mass removes this scale ambiguity; a predicted label for
an unknown object adds no independent calibration information. In a static
sensitivity calculation over 50 objects, an unmodeled $0.1$ W auxiliary
offset gives mass MAE $3.396$ g and mean planar COM error $4.568$ mm while
mean power-fit RMSE is $0.007275$ W. Small reconstruction residuals alone
therefore do not establish accurate payload parameters.

## 2. Probing and physical inversion

Estimator inputs consist of aggregate power, native encoders, commands, and
timestamps. Measured torques, individual simulated currents, and hidden
simulator states are excluded.

The eight target joint vectors, in degrees in the reduced-model coordinates,
are:

1. $(-15,-55,45,-30)$.
2. $(0,-40,45,-10)$.
3. $(15,-50,65,5)$.
4. $(25,-30,50,25)$.
5. $(10,-45,55,40)$.
6. $(-5,-25,40,45)$.
7. $(-20,-40,65,20)$.
8. $(0,-50,50,-15)$.

The 22.6 s sequence starts with a 1 s wait, then eight 1.5 s transitions,
each followed by a 1.2 s hold. The first transition repeats the starting
pose; subsequent transitions use $10u^3-15u^4+6u^5$, where $u$ is normalized
transition time. The final window of each hold supplies mean position $q_k$,
mean power $\bar P_k$, and power SD $s_{P,k}$. Stationarity requires

$$
\frac{\|q(t_b)-q(t_a)\|_2}{T_w}<v_{\mathrm{stat}},\qquad
\max_i\left(\max_{[t_a,t_b]}q_i-\min_{[t_a,t_b]}q_i\right)<q_{\mathrm{stat}},
\qquad t_b-t_a=T_w.
$$

Use $T_w=0.3$ s, $v_{\mathrm{stat}}=0.035$ rad/s, and
$q_{\mathrm{stat}}=0.012$ rad. All eight windows must be complete and
stationary. Power SD measures within-window variation, not the standard error
of the mean. The physical inverse, also called the teacher in code, fits
poses 2–7 and reserves poses 1 and 8 for evaluation. Residual estimators use
all eight poses.

Write $P_k(\theta;\eta)=F_k(\beta(\theta);\eta)$. Initialization solves

$$
\theta_0=\underset{\theta\in\mathcal B}{\operatorname{argmin}}
\sum_{k\in\{2,\ldots,7\}}
\left[\frac{P_k(\theta;\eta)-\bar P_k}{\sigma_k}\right]^2,
\qquad \sigma_k=\max(s_{P,k},\sigma_{P,\min}),
$$

where $\sigma_{P,\min}=0.04$ W and
$\mathcal B=[0.06,0.25]\ \mathrm{kg}\times[0.04,0.20]\ \mathrm m
\times[-0.025,0.025]\ \mathrm m$.

`lsqnonlin` uses an analytic Jacobian, at most 300 iterations,
function and step tolerances $10^{-10}$, and optimality tolerance $10^{-9}$.
Seven starts in normalized box coordinates are

$$
\mathcal U_0=\left\{
\begin{aligned}
&(u_c,u_c,u_c),(u_l,u_l,u_l),(u_h,u_h,u_h),\\
&(u_l,u_h,u_h),(u_h,u_l,u_l),(u_c,u_l,u_h),(u_c,u_h,u_l)
\end{aligned}\right\},
\qquad (u_l,u_c,u_h)=(0.15,0.50,0.85).
$$

Retain the solution with the lowest finite objective. Acceptance requires a
positive exit flag, numerical rank three, and

$$
\begin{aligned}
\mathrm{RMSE}_{\mathrm{fit}}&\leq\varepsilon_{P,\mathrm{fit}},&
\mathrm{RMSE}_{\mathrm{check}}&\leq\varepsilon_{P,\mathrm{check}},\\
\sigma_{\min}(J_s)&\geq\underline\sigma_J,&
\operatorname{cond}(J_s)&\leq\kappa_{J,\max}.
\end{aligned}
$$

$J_s$ is the fitting Jacobian scaled by solver-box spans and
$\sigma_k^{-1}$. Thresholds are
$\varepsilon_{P,\mathrm{fit}}=0.15$ W,
$\varepsilon_{P,\mathrm{check}}=0.20$ W,
$\underline\sigma_J=1$, and $\kappa_{J,\max}=10^5$.
`physics6` denotes this inverse. `physics8` fits all eight poses with the same
settings, omitting the held-out residual criterion. Finite rejected estimates
remain available for scoring and diagnosis. Teacher rejection or `physics8`
failure alone does not exclude an otherwise finite learning record.

## 3. Residual predictors

### Features

The 13-feature representation is

$$
x_R=\left[(\theta_0\oslash s_\theta)^{\mathsf T},\;
\left(\frac{\bar P_k-P_k(\theta_0;\eta)}{\sigma_{P,\min}}\right)_{k=1}^{8},\;
\mathrm{RMSE}_{\mathrm{fit}},\;\mathrm{RMSE}_{\mathrm{check}}\right]^{\mathsf T},
$$

where $\oslash$ denotes componentwise division and
$s_\theta=(0.14\ \mathrm{kg},0.14\ \mathrm m,0.036\ \mathrm m)$.
RMSE inputs stay in watts until standardization.

For sensitivity features, evaluate $J_\theta$ at $\theta_0$ and form

$$
G=D_\sigma^{-1}J_\theta\operatorname{diag}(s_\theta),\qquad
r=D_\sigma^{-1}[\bar P-P(\theta_0;\eta)],\qquad
v=(G^{\mathsf T}G+\lambda_G I)^{-1}G^{\mathsf T}r.
$$

$D_\sigma$ contains $\sigma_k$, $\lambda_G=10^{-3}$ is fixed numerical
damping, and $\sigma_w=0.04$ W. The 52-feature representation appends to
the 13 features: 24 entries of $G$, eight values $s_{P,k}/\sigma_w$, three
entries of $v$, three values $\log_{10}(1+\sigma_j(G))$, and
$\log_{10}(1+\operatorname{cond}(G))$, with a machine-precision denominator
floor. These features use nominal calibration and measured summaries, not
labels, nuisance factors, or transient simulator information.

### Ridge and neural models

`ridge13` and `ridgeAug` regress $\theta-\theta_0$ on 13 and 52 features,
respectively, using squared error, penalized coefficients, and an unpenalized
intercept. Each independently searches penalties
$\{10^{-7},10^{-6},\ldots,1\}$. `interactionRidge` adds the 91 products
$z_i z_j$, $i\leq j$, of the first 13 standardized inputs to the 52 features,
then standardizes all 143 predictors.

For training means $\mu_X$ and SDs $s_X$, set
$z=(x-\mu_X)\oslash s_X$. Predictions take the form

$$
\hat\theta=\theta_0+R(x)+\alpha\,d_R\odot f_W(z).
$$

For $n$ eligible training records, residuals and output amplitudes are

$$
u_i=\theta_i-\theta_{0i}-R(x_i),\qquad
d_{R,j}=\max\left\{\sqrt{n^{-1}\sum_i u_{ij}^2},d_{R,\min,j}\right\}.
$$

`ridgeSkipNN13` and `ridgeSkipNNaug` use the selected `ridge13` and
`ridgeAug` as fixed $R$; `scaledNN13` uses $R=0$. Means, SDs, and RMS
amplitudes come from training data only. SDs below $10^{-10}$ are replaced
by one. Output-amplitude floors are $10^{-5}$ kg for mass and $10^{-5}$ m
per COM coordinate. Zero output-layer weights and biases make the initial
skip model reproduce ridge exactly. Training fixes $\alpha=1$; validation
rescales completed ensembles using
$\alpha\in\{0,0.25,0.5,0.75,1\}$, including the ridge fallback at zero.

Physical amplitudes are restored before the neural loss is evaluated:

$$
\mathcal L=\frac{1}{n}\sum_i\frac{
\sqrt{(e_{im}/t_m)^2+\epsilon_\ell^2}-\epsilon_\ell+
\sqrt{\|e_{ic}\|_2^2/t_c^2+\epsilon_\ell^2}-\epsilon_\ell}{2}
+\frac{\lambda_N}{2}\sum_\ell\|W_\ell\|_F^2,
$$

with $e=\hat\theta-\theta$, $e_c=(e_{c_x},e_{c_z})$, $t_m=1$ g,
$t_c=1$ mm, and $\epsilon_\ell=0.1$. Only weight matrices are penalized.
Minibatches estimate the empirical training loss.

Each of the three neural families uses tanh layouts $[16]$ and $[32,16]$
with penalties $\{10^{-6},10^{-4},10^{-2}\}$, giving six combinations.
Each combination uses seeds 1430101, 1430102, and 1430103: 54 fits total.
Adam uses batch size 256, learning rate 0.001, moments 0.9/0.999, and
offset $10^{-8}$. Training permits 1,500 epochs with validation patience
150. Each member retains the epoch with lowest smooth physical validation
loss, including epoch zero. Predictions are averaged equally across seeds
in physical units before scoring or common clipping.

A compact NN13 control adds three fits on the same data, with eight tanh
units, domain-span response scales, penalty 0.001, and `fitrnet` LBFGS
with 800 iterations and validation patience 30.

### Selection rules

`ridge13` minimizes validation mass MAE/$t_m$ plus mean planar distance/$t_c$.
Other candidates minimize the largest of eight condition/metric ratios to
the selected `ridge13`. Ties are broken by mean ratio, pooled physical
score, and fixed order. Selection among the three scaled neural families
uses the first two criteria and fixed family order. This differs from epoch
retention. Ridge and neural loss, preprocessing, and search budgets differ,
so these comparisons evaluate complete estimators rather than nonlinearity
alone. Training and validation objects alone determine model selection.

## 4. Nominal plant and generated observations

The yaw–pitch–pitch–pitch rigid-body arm uses MATLAB R2026a, local PID
control, friction, actuator limits, and 1 ms integration. Pitch-link lengths
are $(0.23870809,0.21600955,0.06811302)$ m and masses are
$(0.11642973,0.15987536,0.00475299)$ kg. Prescribed unloaded mass is
0.826 kg and gravity is $9.81$ m/s². Nominal auxiliary draw is 2 W;
holding coefficients are $3.74335616(1,0.5,1,1)$ W/(N m)². These are
simulation priors requiring calibration for hardware use. Source and
configuration files specify the inertia tensors and controller parameters.

Host commands and encoder samples follow a 50 ms cadence independently
of transport delay; power is sampled every 10 ms. Command and encoder-return
delays are independently uniform over 10–15 ms, rounded upward to the
integration grid. Undelayed power is paired with the latest available
encoder value. Gaussian encoder noise has SD $10^{-4}$ rad before
4096-count/revolution quantization; sample power-noise SD is 0.03 W.
Packet loss and clock drift are excluded.

Independent Latin-hypercube designs sample

$$
\mathcal D_{\mathrm{gen}}=
[m_{g,\min},m_{g,\max}]\times
[c_{x,g,\min},c_{x,g,\max}]\times
[c_{z,g,\min},c_{z,g,\max}],
$$

using intervals $[0.08,0.22]$ kg, $[0.05,0.19]$ m, and
$[-0.018,0.018]$ m. A dense sub-box in a fixed $(0.256,0.060,0.080)$ m
envelope determines physically admissible inertia from mass and COM.
Learning uses steady holding summaries with this inertia construction.
Training, validation, and test sets contain 12,000, 2,000, and 2,000
disjoint objects. Training and validation use one episode per object,
balanced across four condition families. Every test object undergoes all
four conditions: 8,000 test episodes and 22,000 episodes overall.

Nominal conditions have no added mismatch. Under mechanical mismatch,
each departure is independently multiplied by a uniform factor in
$[0.5,1.5]$:

- Link mass/inertia scale departures: $(0.025,-0.02,0.03)$.
- Longitudinal COM shifts: $(1,-1,1.5)$ mm.
- Friction scale departures: $(0.15,0.35,0.25,0.40)$.
- PID gain departures: $(-0.02,-0.06,-0.04,-0.08)$.

Electrical mismatch adds

$$
\Delta P=\alpha_P\sum_i|\tau_i|+\gamma_P\sum_i\tau_i^4.
$$

Base coefficients are $\alpha_P=0.03285784$ W/(N m) and
$\gamma_P=0.02100986$ W/(N m)⁴, independently multiplied by factors from
the same distribution. At their base values the terms contribute equally,
totaling 2% of nominal mean static power for reference payload
$(m,c_x,c_z)=(0.15,0.12,0)$ in SI units. The combined condition includes
both mechanisms. Nuisance, sensor, and communication draws are independent
between episodes. Conditions are paired by object, not by noise realization;
parameters stay fixed within a probe. Training and test use the same
prescribed mismatch distributions.

All learning methods require finite features, teacher estimates, and targets,
with at least 100 examples per condition family in each fitting split.
Failed records are retained without replacement. Sampling plans, code, and
seeds are fixed before generation; estimator parameters are fixed before
test generation. These objects are disjoint from the reference-assisted
adaptation data. Split seeds are 1410101–1410103. Sensor, communication,
and nuisance seeds are respectively 14200000, 14400000, and 14500000 plus
trial ID.

## 5. Electrothermal plant

An additional plant evolves joint angle, velocity, motor current, controller
integral state, temperature, and an energy ledger. With quantities referred
to the output shaft, each drive obeys

$$
\begin{aligned}
L_i\dot i_i &= v_i-d_i(i_i)-R_i i_i-K_i\dot q_i,
&\tau_i&=K_i i_i,\\
R_i &= R_{i,0}\rho_i[1+\alpha_T(T_i-T_a)],
&d_i(i_i)&=v_{d,i}\tanh(i_i/i_s)+r_{b,i}i_i,\\
C_{T,i}\dot T_i&=R_i i_i^2-h_i(T_i-T_a),
&P_{\mathrm{bus}}&=P_a+\sum_i\max(v_i i_i,0).
\end{aligned}
$$

The same SI coefficient $K_i$ relates current to torque and velocity to back
EMF. In this thermal equation $h_i$ is a cooling coefficient, distinct from
the static electrical coefficient in $D$. An ideal nonregenerative 12 V bus
supplies the drives; negative bridge power is dissipated locally. Cold
resistances obey $R_{i,0}/K_i^2=b_i$, with $b_i$ equal to the nominal
holding-loss coefficients in Section 4. Both plants thus share cold static
calibration. $P_a$ includes a prescribed offset and low-frequency ripple.

Geometry, outer-loop gains, and stall-torque ratings remain nominal.
Position error, velocity damping, and integral torque set a saturated
current reference; a current loop follows with bus-voltage saturation.
This differs from the nominal speed-dependent torque-envelope controller.
Stribeck friction, electrical dynamics, bridge losses, and temperature add
further departures. Source code specifies saturation and anti-windup rules.

### Parameter paths and initial conditions

Fixed parameters are:

- Torque/back-EMF coefficient: $K_i=2.941995/2.7$ in SI units.
- Current-loop gain: 3 Ω; current limits: $(2.7,5.4,2.7,2.7)$ A.
- Inductances: $(0.025,0.018,0.022,0.012)$ H.
- Thermal capacities: $(12,24,12,8)$ J/K.
- Cooling coefficients: $(0.25,0.50,0.25,0.18)$ W/K.
- Ambient temperature: $T_a=25\,{}^\circ$C; current smoothing: $i_s=0.05$ A.
- Friction smoothing and Stribeck speed: 0.02 and 0.08 rad/s.

Mechanical departures at severity $s=1$ are:

- Link mass scales: $(0.04,-0.03,0.05)$.
- Link COM shifts $(x,y,z)$: $(1.5,0,-0.5)$, $(-1,0,0.8)$, and
  $(1,0,0.5)$ mm.
- Viscous friction scales: $(0.4,0.6,0.5,0.4)$.
- Coulomb friction scales: $(0.3,0.5,0.4,0.3)$.
- Stribeck torques: $(0.025,0.040,0.025,0.015)$ N m.
- Controller gain scales: $(-0.06,-0.10,-0.08,-0.06)$.

Electrical departures at $s=1$ are:

- Resistance scales $\rho_i-1$: $(0.06,0.08,0.05,0.07)$.
- Initial temperature rises: $(6,9,7,5)$ K.
- Bridge voltage drops $v_{d,i}$: $(0.10,0.14,0.12,0.08)$ V.
- Bridge resistive terms $r_{b,i}$: $(0.08,0.06,0.08,0.08)$ Ω.
- Common thermal coefficient in electrical/combined conditions:
  $\alpha_T=s\,0.00393$ K⁻¹.
- Auxiliary offset: $s\,0.10$ W; ripple amplitude: $s\,0.05$ W at 0.07 Hz.

Each nonzero departure is multiplied by severity $s$ and its fixed uniform
nuisance factor in $[0.8,1.2]$, except the common $\alpha_T$ and auxiliary
terms. Each link's mass and COM changes share a factor. Coulomb and
Stribeck terms share axis factors, as do each axis's two bridge-loss terms.
Auxiliary ripple uses a fixed uniform phase. These parameters are prescribed
to examine mechanisms, not identified from a physical device.

Baseline and mechanical-only cases have $\alpha_T=0$ and no additional
electrical departures. Electrical-only cases have no additional mechanical
departures. Velocity, current, and integral torque start at zero at the first
pose. Initial temperature rise and $\alpha_T$ each scale with $s$, so their
product is quadratic in $s$; severity is not a linear loss scale. Backlash,
structural compliance, contact, and source-voltage sag are excluded.
Individual currents remain excluded from estimator inputs.

Twelve additional Latin-hypercube objects each undergo a baseline and
mechanical, electrical, and combined conditions at
$s\in\{0.1,0.25,0.5,1\}$, for 156 episodes. Nuisance, sensor, and
communication draws are paired within each object. The probe, observations,
fixed estimators, and thresholds remain unchanged. The plant shares the
rigid-body backend and cold calibration with the nominal plant.

### Integration sensitivity

MATLAB `ode15s` uses relative tolerance $\varepsilon_r=2\times10^{-6}$,
absolute tolerance $\varepsilon_a=10^{-8}$, and maximum step
$h_{\max}=5$ ms. Numerical sensitivity is evaluated on a complete 22.6 s
combined-condition trajectory at $s=1$, using the fixed first development
payload. Dividing both tolerances by four and halving $h_{\max}$, with
observation times and random draws fixed, changes angle, current, temperature,
and plateau power by at most $1.60\times10^{-7}$ rad,
$5.52\times10^{-6}$ A, $9.41\times10^{-7}$ K, and
$5.69\times10^{-6}$ W. This is local numerical sensitivity for one
trajectory, not a full-domain convergence result.

### Signed power accounting

For a saved holding sample, let $P_0$ be nominal power at its true angle
and payload, $a_0$ the nominal auxiliary draw, and $\tau_{0i}$ its nominal
torque. The exact signed accounting identity is

$$
\begin{aligned}
P_{\mathrm{bus}}-P_0={}&(P_a-a_0)+\sum_i d_i(i_i)i_i
+\sum_i(R_i-R_{i,0})i_i^2\\
&+\sum_iR_{i,0}\left[i_i^2-(\tau_{0i}/K_i)^2\right]
+P_{\mathrm{shaft}}+P_{\mathrm{brake}}+P_{\mathrm{mag}},
\end{aligned}
$$

where

$$
P_{\mathrm{shaft}}=\sum_iK_i i_i\dot q_i,\qquad
P_{\mathrm{brake}}=\sum_i\max(-v_i i_i,0),\qquad
P_{\mathrm{mag}}=\sum_iL_i i_i\dot i_i.
$$

The resistance term separates into cold-scale and thermal contributions.
Magnetic power follows directly from the circuit equation. Evaluate the
identity before averaging: 31 samples per pose, eight poses per episode,
and 156 episodes give 38,688 samples for algebraic closure. The payload
object, not the individual holding sample, remains the independent unit for
statistical inference.

### Mismatch projected onto payload sensitivity

Evaluate the nominal power Jacobian $J$ at true payload parameters and
observed mean angles. Set
$p_{0,k}=P_{\mathrm{nominal}}(\bar q_k,\theta_{\mathrm{true}})$.
This differs from the samplewise true-angle power used in signed accounting.
For the six fitting poses define

$$
A=\Sigma^{-1}JS_\theta,\qquad
b=\Sigma^{-1}(\bar P-p_0),\qquad
\Sigma=\operatorname{diag}[\max(s_{P,k},\sigma_{P,\min})],
$$

with $\sigma_{P,\min}=0.04$ W and solver-box-span scaling
$S_\theta=\operatorname{diag}(0.19\ \mathrm{kg},0.16\ \mathrm m,0.05\ \mathrm m)$.
Use the per-pose sample SD, not a standard error. The least-squares step
and absorbed fraction are

$$
u=A^\dagger b,\qquad
\Delta\theta=S_\theta u,\qquad
\chi=\frac{\|Au\|_2^2}{\|b\|_2^2}.
$$

The ratio is undefined for zero residual; the implementation returns `NaN`
when $\|b\|_2$ does not exceed machine epsilon.

Evaluate the resulting power change at the two withheld poses as well.
This local diagnostic may leave the physical box and uses true parameters;
it is not an estimate available to a robot or a Fisher-information calculation
for the changed plant. True-state diagnostics do not enter fitting or
estimator inputs.

## 6. Matched affine controls

An affine branch replaces $f_W$ while retaining the 13 inputs, fixed ridge
skip, training-only standardization, response amplitudes, physical loss, and
three-seed averaging. A fixed comparison uses the selected 16-unit nonlinear
branch and a 42-parameter affine branch, each with $\lambda_N=10^{-4}$ and
$\alpha=0.5$. Adam settings and validation stopping are identical. Equal
penalty coefficients do not necessarily regularize the function classes
equally.

Affine selection searches six penalties from $10^{-7}$ to $10^{-2}$ and
the same five correction strengths. Fixed and validation-selected variants,
including the ridge fallback, are evaluated on 500 additional objects
under all four nominal-generator conditions: 2,000 complete trajectories.
Descriptive 95% intervals use 5,000 paired object resamples without
multiplicity adjustment.

The affine objective is also solved in double precision, fixing the original
single-rounded design and constants. Analytical gradients and Hessians are
compared with finite differences. Damped Newton iterations solve each of
the six penalties from zero and from three retained Adam solutions.
Training-gradient and decrement tolerances are $\varepsilon_g=10^{-7}$
and $\varepsilon_d=10^{-11}$; the latter scales with
$\max(1,|\mathcal L|)$. These are numerical-stationarity criteria independent
of validation performance. Solutions must agree across initializations and
remain consistent under single-precision inference. One comparator retains
the fixed penalty and correction strength; another uses the validation rule
in Section 3. This post hoc optimization analysis reuses the 500-object and
12-object panels, keeping the nonlinear model fixed.

## 7. Reference-assisted adaptation

Adaptation uses a separate compact residual ensemble of three members, each
with eight hidden units, initialized on nominal data. The fixed ridge-skip
estimator is not updated online. Each block stores predictions for four
unknown objects, then probes one known empty state, four training references,
and two distinct validation references, in that order.

Training-reference $(m,c_x,c_z)$ vectors in kilograms and meters are
$(0.09,0.06,-0.014)$, $(0.21,0.07,0.014)$, $(0.10,0.18,0.012)$, and
$(0.20,0.17,-0.012)$. Validation references are $(0.12,0.10,-0.005)$ and
$(0.18,0.145,0.007)$. Unknown ground truth is used only for generation and
scoring. Validation-reference labels never enter fitting.

### Calibration proposals and replay

The empty probe estimates absolute auxiliary draw
$a\in[a_{\min},a_{\max}]$ and multiplier
$\lambda\in[\lambda_{\min},\lambda_{\max}]$ on original nominal pitch-axis
holding coefficients. Bounds are $[a_{\min},a_{\max}]=[0,6]$ W and
$[\lambda_{\min},\lambda_{\max}]=[0.3,2.5]$. Six poses fit calibration and
two are withheld. A proposal requires scaled-design condition number at most
$10^5$, fitting and held-out RMSE at most $0.12$ W, and held-out RMSE
deterioration at most $0.004$ W.

Candidates update the network, calibration, or both. Every calibration change
must pass this screen; reference features are recomputed for every candidate.
Network refitting combines the nominal cache with up to 32 current and
historical training-reference measurements, weighted 1 and 30, respectively.
Each member permits 300 iterations with validation patience 30. One failed
fit rejects the candidate. Usable training references enter replay even when
the update is not deployed.

### Deployment gate

Use raw predictions at the two current validation references:

$$
\ell_r=\|\operatorname{diag}(s_\theta)^{-1}
(\hat\theta_r-\theta_r)\|_2^2/3,\qquad
L=(\ell_1+\ell_2)/2,
$$

where $s_\theta=(0.14\ \mathrm{kg},0.14\ \mathrm m,0.036\ \mathrm m)^{\mathsf T}$.
Improvement and nominal retention require

$$
\begin{aligned}
L_{\mathrm{new}}&\leq L_{\mathrm{old}}-
\max(\varepsilon_u,\rho_u L_{\mathrm{old}}),\\
L_{\mathrm{nom}}(\eta_0,W_{\mathrm{new}})&\leq
\gamma_{\mathrm{nom}}L_{\mathrm{nom}}(\eta_0,W_0).
\end{aligned}
$$

Also impose

$$
\max_r\ell_{r,\mathrm{new}}\leq
\gamma_w\max_r\ell_{r,\mathrm{old}}+\varepsilon_u,
$$

and limit component-MAE increases to $\Delta_k$.
Use $\varepsilon_u=10^{-6}$, $\rho_u=0.05$,
$\gamma_{\mathrm{nom}}=1.25$, $\gamma_w=1.05$, and
$\Delta=(0.15\ \mathrm g,0.5\ \mathrm{mm},0.5\ \mathrm{mm})$.
These exclude negligible improvements, require relative improvement, limit
nominal forgetting, and bound local component and worst-reference deterioration.

Settings are chosen independently of unknown-object outcomes and fixed before
evaluation. Reference features must be usable and physical acceptance coverage
must not decrease. $L_{\mathrm{nom}}$ averages $\ell$ over a fixed nominal
validation set, using original-calibration inputs and each learner's initial
model. Deploy the passing candidate with lowest reference loss; if none
passes, retain calibration and weights. Scoring retains every finite raw
unknown prediction, including rejected estimates. Unknown-object evaluation
is separate from reference selection.

### Drift and stream design

Stationary, electrical, mechanical, and combined scenarios each contain
eight object/noise streams of four blocks: 1,408 probes, including 512
unknown events from 128 distinct payloads paired across scenarios. Drift
follows prescribed powers of cubic smoothstep
$z(\rho)=3\rho^2-2\rho^3$, where $\rho$ is normalized episode progress,
with axis-specific exponents. Parameters remain constant within a probe.

Electrical drift reaches 1.30 times nominal pitch holding losses and
2.20 W auxiliary draw. Mechanical drift reaches friction multipliers
$(1.40,1.80,1.60,2.00)$ and PID-gain multipliers
$(0.92,0.85,0.88,0.82)$. Command delay is fixed at 20 ms, with no
encoder-return transport delay or added communication jitter. This timing
configuration differs from the 10–15 ms independent-direction jitter in
Section 4.

Frozen, empty-only, gated-calibration, and full adaptation variants require
0, 1, 3, and 7 reference probes per opportunity. Seven probes take 158.2 s,
excluding handling. Drift reaches its endpoint at the final reference probe;
no unknown-object observation follows the last update.

Adaptive ridge uses identical recorded observations, ordering, reference
weights, replay pool, calibration proposals, and gate thresholds. Both
learners fit domain-normalized targets $(\theta-\theta_0)\oslash s_\theta$.
Ridge refits 13 features with penalty 0.001 and an unpenalized intercept,
dividing weighted squared error by total weight. It retains offline
standardization and uses a deterministic closed-form fit. Neural refits
recompute standardization and stop on validation performance. Each learner
retains its own initial nominal-loss baseline, so identical gates can accept
different updates. Descriptive paired intervals use 4,000 complete
object/noise-stream resamples without multiplicity adjustment.

## Mathematical references

1. Rothenberg TJ. Identification in parametric models. *Econometrica* 1971;
   39: 577–591. [DOI](https://doi.org/10.2307/1913267).
2. Huang M and Xu Z. Phase retrieval from the norms of affine transformations.
   *Advances in Applied Mathematics* 2021; 130: 102243.
   [DOI](https://doi.org/10.1016/j.aam.2021.102243).
3. Mirsky L. Symmetric gauge functions and unitarily invariant norms.
   *Quarterly Journal of Mathematics* 1960; 11: 50–59.
   [DOI](https://doi.org/10.1093/qmath/11.1.50).
4. Scharf LL and McWhorter LT. Geometry of the Cramer–Rao bound.
   *Signal Processing* 1993; 31: 301–311.
   [DOI](https://doi.org/10.1016/0165-1684(93)90088-R).
