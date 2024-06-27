
RPS ?= 1024
WAIT_TIME ?= 60
BATCH_PERIOD ?= 1s
POOL_SIZE ?= 1

TOOLS_FOLDER := $(abspath tools)

ISTIO_VERSION := 1.22.1
ISTIO_FOLDER := ${TOOLS_FOLDER}/istio-${ISTIO_VERSION}
ISTIOCTL := ${ISTIO_FOLDER}/bin/istioctl
${ISTIOCTL}:
	mkdir -p ${TOOLS_FOLDER}
	cd ${TOOLS_FOLDER} && (curl -L https://istio.io/downloadIstio | ISTIO_VERSION=${ISTIO_VERSION} sh)

KIND_FOLDER := ${TOOLS_FOLDER}/kind
KIND := ${KIND_FOLDER}/kind
KIND_VERSION := v0.23.0
${KIND}:
	mkdir -p ${KIND_FOLDER}
	GOBIN=${KIND_FOLDER} go install sigs.k8s.io/kind@${KIND_VERSION}

.PHONY: build
build:
	docker compose build

secrets:
	mkdir secrets
	openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout secrets/tls.key -out secrets/tls.crt -subj "/CN=foo.bar.com"

.PHONY: up-kind
up-kind: ${KIND} build secrets
	mkdir -p .kube
	${KIND} create cluster --config cluster.yaml --kubeconfig .kube/config
	${KIND} load docker-image --name benchmark-istio benchmark-envoy/benchmark-envoy:latest
	kubectl create ns --kubeconfig .kube/config test
	kubectl create secret tls test-tls -n test --key="secrets/tls.key" --cert="secrets/tls.crt" --kubeconfig .kube/config

.PHONY: up-istio
up-istio: ${ISTIOCTL} up-kind
	${ISTIOCTL} install -y --kubeconfig .kube/config \
		--set values.pilot.env.ENABLE_TLS_ON_SIDECAR_INGRESS=true
	kubectl label ns --kubeconfig .kube/config test istio-injection=enabled

.PHONY: run
run:
	kubectl apply --kubeconfig .kube/config -f kubernetes-configs/server.yaml
	RPS=${RPS} BATCH_PERIOD=${BATCH_PERIOD} POOL_SIZE=${POOL_SIZE} envsubst < kubernetes-configs/client.yaml | kubectl apply --kubeconfig .kube/config -f -
	sleep 10
	kubectl logs --kubeconfig .kube/config -n test -l app=client -f

.PHONY: run-tls
run-tls:
	kubectl apply --kubeconfig .kube/config -f kubernetes-configs/server-tls.yaml
	RPS=${RPS} BATCH_PERIOD=${BATCH_PERIOD} POOL_SIZE=${POOL_SIZE} envsubst < kubernetes-configs/client.yaml | kubectl apply --kubeconfig .kube/config -f -
	sleep 10
	kubectl logs --kubeconfig .kube/config -n test -l app=client -f

.PHONY: get-client-logs
get-client-logs:
	kubectl logs --kubeconfig .kube/config -n test -l app=client

.PHONY: port-forward-server
port-forward-server:
	kubectl port-forward --kubeconfig .kube/config deployment/server 8080:80

.PHONY: clean
clean: ${KIND}
	${KIND} delete cluster --name benchmark-istio