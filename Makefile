
RPS ?= 1024
WAIT_TIME ?= 60

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

.PHONY: up-kind
up-kind: ${KIND} build
	mkdir -p .kube
	${KIND} create cluster --config cluster.yaml --kubeconfig .kube/config
	${KIND} load docker-image --name benchmark-istio benchmark-envoy/benchmark-envoy:latest

.PHONY: up-istio
up-istio: ${ISTIOCTL} up-kind
	${ISTIOCTL} install -y --kubeconfig .kube/config

.PHONY: run
run:
	RPS=${RPS} envsubst < kubernetes-configs/server.yaml | kubectl apply --kubeconfig .kube/config -f -
	RPS=${RPS} envsubst < kubernetes-configs/client.yaml | kubectl apply --kubeconfig .kube/config -f -
	sleep ${WAIT_TIME}
	kubectl logs --kubeconfig .kube/config -l app=client

.PHONY: get-client-logs
get-client-logs:
	kubectl logs --kubeconfig .kube/config -l app=client

.PHONY: clean
clean: ${KIND}
	${KIND} delete cluster --name benchmark-istio