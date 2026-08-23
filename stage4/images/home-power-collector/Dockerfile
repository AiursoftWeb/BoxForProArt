FROM --platform=$BUILDPLATFORM hub.aiursoft.com/aiursoft/internalimages/dotnet AS build-env
ARG TARGETARCH
WORKDIR /src

COPY . .

RUN if [ "$TARGETARCH" = "arm64" ]; then \
        RID="linux-arm64"; \
    elif [ "$TARGETARCH" = "amd64" ]; then \
        RID="linux-x64"; \
    else \
        RID="linux-$TARGETARCH"; \
    fi && \
    echo "Building for arch: $TARGETARCH, using .NET RID: $RID" && \
    dotnet publish HomePowerCollector.csproj \
        --configuration Release \
        --no-self-contained \
        --runtime "$RID" \
        --output /app

FROM hub.aiursoft.com/aiursoft/internalimages/dotnetonlyruntime
WORKDIR /app
COPY --from=build-env /app .

ENTRYPOINT ["dotnet", "HomePowerCollector.dll"]
