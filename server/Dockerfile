# Runtime-only image. The binary is cross-compiled on the build machine by
# deploy/build-image.sh (PocketBase uses a pure-Go SQLite driver, so no CGO),
# which keeps the image build free of any network access and emulation.

ARG RUNTIME_IMAGE=alpine:3.24.2
FROM ${RUNTIME_IMAGE}

WORKDIR /app
COPY .build/couple-ledger /app/couple-ledger
# numeric uid so no passwd entry (and no RUN) is needed; deploy scripts chown the data dir
USER 10001:10001
EXPOSE 8090
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8090/api/health || exit 1
ENTRYPOINT ["/app/couple-ledger"]
CMD ["serve", "--http=0.0.0.0:8090", "--dir=/app/pb_data"]
