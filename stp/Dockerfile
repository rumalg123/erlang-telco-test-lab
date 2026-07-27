# syntax=docker/dockerfile:1

ARG ERLANG_IMAGE=erlang:29.0.3.0-slim
ARG RUNTIME_IMAGE=debian:trixie-slim
ARG STP_VERSION=0.3.0
ARG STP_RELEASE_VERSION=1.0

FROM ${ERLANG_IMAGE} AS builder

ARG STP_VERSION
ARG STP_RELEASE_VERSION

WORKDIR /build/stp

COPY src/ ./src/
COPY include/ ./include/
COPY test/ ./test/
COPY release/ ./release/
COPY deploy/system/releases/ ./deploy/system/releases/

RUN set -eux; \
    grep -F "{vsn, \"${STP_VERSION}\"}" src/telco_stp.app.src; \
    mkdir -p /build/output/ebin /build/output/test; \
    erlc +debug_info -Werror \
        -I include \
        -o /build/output/ebin \
        src/telco_stp_transport.erl; \
    for source in src/*.erl; do \
        if [ "${source}" != "src/telco_stp_transport.erl" ]; then \
            erlc +debug_info -Werror \
                -I include \
                -pa /build/output/ebin \
                -o /build/output/ebin \
                "${source}"; \
        fi; \
    done; \
    cp src/telco_stp.app.src \
        /build/output/ebin/telco_stp.app; \
    cp src/telco_stp.appup.src \
        /build/output/ebin/telco_stp.appup; \
    for test_source in test/*.erl; do \
        erlc +debug_info -Werror \
            -I include \
            -pa /build/output/ebin \
            -o /build/output/test \
            "${test_source}"; \
    done; \
    erl \
        -pa /build/output/test \
        -pa /build/output/ebin \
        -noshell \
        -s telco_stp_test_runner run; \
    escript release/build_release.escript \
        /build/output/ebin \
        "deploy/system/releases/${STP_RELEASE_VERSION}/sys.config" \
        "deploy/system/releases/${STP_RELEASE_VERSION}/vm.args" \
        release/bin/telco_stp \
        /build/release-root \
        "${STP_RELEASE_VERSION}" \
        "${STP_VERSION}"

FROM ${RUNTIME_IMAGE} AS runtime

ARG STP_VERSION
ARG STP_RELEASE_VERSION

LABEL org.opencontainers.image.title="telco_stp"
LABEL org.opencontainers.image.version="${STP_VERSION}"
LABEL org.opencontainers.image.description="Erlang/OTP 29 SS7/SIGTRAN STP interoperability lab"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        iproute2 \
        libodbc2 \
        libssl3t64 \
        libsctp1 \
        lksctp-tools \
        procps; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --gid 10001 stp; \
    useradd \
        --uid 10001 \
        --gid 10001 \
        --home-dir /lab/stp/db \
        --no-create-home \
        --shell /usr/sbin/nologin \
        stp

WORKDIR /lab/stp

RUN mkdir -p \
        /opt/telco_stp/system \
        /lab/stp/system \
        /lab/stp/logs/trace \
        /lab/stp/crash_dumps \
        /lab/stp/db/snapshots \
        /lab/stp/pipe \
        /lab/stp/secrets; \
    chown -R 10001:10001 /lab/stp /opt/telco_stp

COPY --from=builder \
    --chown=10001:10001 \
    /build/release-root/ \
    /opt/telco_stp/system/
COPY --chown=10001:10001 \
    docker/entrypoint.sh \
    docker/healthcheck.sh \
    /usr/local/bin/

RUN set -eux; \
    chmod 0755 \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/healthcheck.sh; \
    read erts_vsn release_vsn \
        < /opt/telco_stp/system/releases/start_erl.data; \
    test "${release_vsn}" = "${STP_RELEASE_VERSION}"; \
    test -x "/opt/telco_stp/system/erts-${erts_vsn}/bin/erlexec"; \
    test -x "/opt/telco_stp/system/erts-${erts_vsn}/bin/run_erl"; \
    test -x "/opt/telco_stp/system/erts-${erts_vsn}/bin/to_erl"; \
    cp \
        "/opt/telco_stp/system/releases/${STP_RELEASE_VERSION}/sys.config" \
        "/opt/telco_stp/system/releases/${STP_RELEASE_VERSION}/sys.config.example"; \
    ln -s \
        "/opt/telco_stp/system/erts-${erts_vsn}/bin/run_erl" \
        /usr/local/bin/run_erl; \
    ln -s \
        "/opt/telco_stp/system/erts-${erts_vsn}/bin/to_erl" \
        /usr/local/bin/to_erl; \
    chown -R 10001:10001 /lab/stp /opt/telco_stp; \
    /opt/telco_stp/system/bin/telco_stp validate; \
    command -v run_erl; \
    command -v to_erl

ENV HOME=/lab/stp/db \
    LANG=C.UTF-8 \
    STP_ROOT=/lab/stp \
    STP_SYSTEM_ROOT=/lab/stp/system \
    STP_SEED_SYSTEM_ROOT=/opt/telco_stp/system \
    STP_APP_VERSION=${STP_VERSION} \
    STP_RELEASE_VERSION=${STP_RELEASE_VERSION} \
    STP_LIVE_EBIN=/lab/stp/system/lib/telco_stp-${STP_VERSION}/ebin \
    STP_SEED_EBIN=/opt/telco_stp/system/lib/telco_stp-${STP_VERSION}/ebin \
    STP_CONFIG_FILE=/lab/stp/system/releases/${STP_RELEASE_VERSION}/sys.config \
    STP_VM_ARGS_FILE=/lab/stp/system/releases/${STP_RELEASE_VERSION}/vm.args \
    STP_RELEASE_COMMAND=/lab/stp/system/bin/telco_stp \
    STP_PIPE_DIR=/lab/stp/pipe \
    STP_LOG_DIR=/lab/stp/logs \
    STP_SYSTEM_MODE=seed \
    STP_EBIN_MODE=seed \
    STP_REQUIRE_SCTP=true \
    ERL_CRASH_DUMP=/lab/stp/crash_dumps/erl_crash.dump \
    RUN_ERL_LOG_ALIVE_IN_UTC=1 \
    RUN_ERL_LOG_GENERATIONS=20 \
    RUN_ERL_LOG_MAXSIZE=10485760

USER 10001:10001

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
HEALTHCHECK \
    --interval=30s \
    --timeout=5s \
    --start-period=20s \
    --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]
