%% Shared STP constants. Keep protocol numbers, persisted schema versions,
%% application environment keys, and table names here instead of scattering
%% literals across modules.

-ifndef(TELCO_STP_HRL).
-define(TELCO_STP_HRL, true).

-define(STP_APP, telco_stp).

%% ETS tables.
-define(STP_METRICS_TABLE, telco_stp_metrics_table).

%% Common integer limits.
-define(STP_UINT32_MAX, 16#ffffffff).
-define(STP_POINT_CODE_MASK_24, 16#ffffff).

%% M3UA / SCTP.
-define(STP_M3UA_VERSION, 1).
-define(STP_M3UA_PPID, 3).
-define(STP_M3UA_PORT, 2905).

%% M2PA / SCTP.
-define(STP_M2PA_VERSION, 1).
-define(STP_M2PA_CLASS, 11).
-define(STP_M2PA_PPID, 5).
-define(STP_M2PA_PORT, 3565).
-define(STP_M2PA_MAX_SEQUENCE, 16#ffffff).

%% SCCP message types.
-define(STP_SCCP_UDT, 16#09).
-define(STP_SCCP_UDTS, 16#0a).
-define(STP_SCCP_XUDT, 16#11).
-define(STP_SCCP_XUDTS, 16#12).
-define(STP_SCCP_LUDT, 16#13).
-define(STP_SCCP_LUDTS, 16#14).

%% Configuration persistence and HA schemas.
-define(STP_CONFIG_MAGIC, <<"TSTPCFG", 1>>).
-define(STP_CONFIG_SCHEMA_VERSION, 1).
-define(STP_HA_SCHEMA_VERSION, 1).

%% Audit.
-define(STP_ZERO_HASH, <<0:256>>).
-define(STP_AUDIT_MAX_FRAME_BYTES, 16777216).

%% GTT.
-define(STP_GTT_DEFAULT_MAX_CHAIN_DEPTH, 8).
-define(STP_GTT_MAX_CHAIN_DEPTH, 64).

%% PCAPNG trace.
-define(STP_PCAPNG_SHB_TYPE, 16#0a0d0d0a).
-define(STP_PCAPNG_IDB_TYPE, 1).
-define(STP_PCAPNG_EPB_TYPE, 6).
-define(STP_PCAPNG_DLT_USER0, 147).

%% Application environment keys.
-define(STP_ENV_AUDIT_HISTORY_LIMIT, audit_history_limit).
-define(STP_ENV_AUDIT_LOG_PATH, audit_log_path).
-define(STP_ENV_GTT_MAX_CHAIN_DEPTH, gtt_max_chain_depth).
-define(STP_ENV_HA, ha).
-define(STP_ENV_RKM_POLICY, rkm_policy).
-define(STP_ENV_TRACE, trace).
-define(STP_ENV_ALARM_HISTORY_LIMIT, alarm_history_limit).
-define(STP_ENV_ACTIVE_ALARM_LIMIT, active_alarm_limit).
-define(STP_ENV_LINKS, links).
-define(STP_ENV_ROUTES, routes).
-define(STP_ENV_GTT_RULES, gtt_rules).
-define(STP_ENV_LISTENERS, listeners).
-define(STP_ENV_FAULT_PROFILE, fault_profile).
-define(STP_ENV_OVERLOAD_LIMITS, overload_limits).
-define(STP_ENV_SCCP_REASSEMBLY_LIMITS, sccp_reassembly_limits).
-define(STP_ENV_MANAGEMENT_CREDENTIALS, management_credentials).

-endif.
