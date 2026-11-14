function H=bpil_hefting_hardware_profile()
% Local measured profile template; no invented mapping or device selection.
H=bdclp_interface_defaults();
H.probe_envelope_verified=false;
H.payload_fixture_verified=false;
H.fixture_only=false;
H.max_rx_buffer_bytes=16384;
H.max_rx_bytes_per_poll=4096;
H.max_tx_backlog_s=.030;
H.profile_scope='Complete local mapping, safe ranges, fixture and swept probe envelope before live use.';
end
