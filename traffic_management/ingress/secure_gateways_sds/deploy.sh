#!/bin/bash

# Task info: https://istio.io/docs/tasks/traffic-management/ingress/secure-ingress-sds/

VER=1.4.0

PATH=$PATH:$PWD/istio-$VER/bin

install_controlplane() {
  curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.4.0 sh -
  pushd istio-$VER
  istioctl manifest apply
  kubectl get pod -n istio-system
  popd
}

get_ingressgateway() {
  kubectl get svc istio-ingressgateway -n istio-system

  export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
  export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].port}')

  echo Ingress host: $INGRESS_HOST
  echo Ingress port: $INGRESS_PORT
  echo Secure Ingress port: $SECURE_INGRESS_PORT

  while [ -z "$INGRESS_HOST" ]
  do
    sleep 10
    export INGRESS_HOST=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    export INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
    export SECURE_INGRESS_PORT=$(kubectl -n istio-system get service istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
    echo Ingress host: $INGRESS_HOST
    echo Ingress port: $INGRESS_PORT
    echo Secure Ingress port: $SECURE_INGRESS_PORT
  done
}

generate_certs() {
  git clone https://github.com/nicholasjackson/mtls-go-example
  pushd mtls-go-example
  ./generate.sh httpbin.example.com 123456
  mkdir ../httpbin.example.com && mv 1_root 2_intermediate 3_application 4_client ../httpbin.example.com
  popd
}

configure_sds_gateway() {
  istioctl manifest generate \
    --set values.gateways.istio-egressgateway.enabled=false \
    --set values.gateways.istio-ingressgateway.sds.enabled=true > \
    istio-ingressgateway.yaml

  kubectl apply -f istio-ingressgateway.yaml
  kubectl get pod -n istio-system
}

setup_httpbin() {
  kubectl apply -f httpbin_example.yaml
  kubectl create -n istio-system secret generic httpbin-credential \
    --from-file=key=httpbin.example.com/3_application/private/httpbin.example.com.key.pem \
    --from-file=cert=httpbin.example.com/3_application/certs/httpbin.example.com.cert.pem
  kubectl apply -f gateway_and_vs.yaml
  kubectl get pod
}

verify_httpbin() {
  curl -v -HHost:httpbin.example.com \
    --resolve httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST \
    --cacert httpbin.example.com/2_intermediate/certs/ca-chain.cert.pem \
    https://httpbin.example.com:$SECURE_INGRESS_PORT/status/418
}

setup_httpbin_mtls() {
  kubectl apply -f httpbin_example.yaml
  kubectl -n istio-system delete secret httpbin-credential
  kubectl create -n istio-system secret generic httpbin-credential  \
    --from-file=key=httpbin.example.com/3_application/private/httpbin.example.com.key.pem \
    --from-file=cert=httpbin.example.com/3_application/certs/httpbin.example.com.cert.pem \
    --from-file=cacert=httpbin.example.com/2_intermediate/certs/ca-chain.cert.pem
  kubectl apply -f gateway_and_vs_mtls.yaml
  kubectl get pod
}

setup_httpbin_mtls_with_hash() {
  kubectl apply -f httpbin_example.yaml
  kubectl -n istio-system delete secret httpbin-credential
  kubectl create -n istio-system secret generic httpbin-credential  \
    --from-file=key=httpbin.example.com/3_application/private/httpbin.example.com.key.pem \
    --from-file=cert=httpbin.example.com/3_application/certs/httpbin.example.com.cert.pem \
    --from-file=cacert=httpbin.example.com/2_intermediate/certs/ca-chain.cert.pem
  kubectl apply -f gateway_and_vs_mtls_hash.yaml
  kubectl get pod
  kubectl get gateway mygateway -o yaml
}

verify_httpbin_mtls() {
  curl -v -HHost:httpbin.example.com \
    --resolve httpbin.example.com:$SECURE_INGRESS_PORT:$INGRESS_HOST \
    --cacert httpbin.example.com/2_intermediate/certs/ca-chain.cert.pem \
    --cert httpbin.example.com/4_client/certs/httpbin.example.com.cert.pem \
    --key httpbin.example.com/4_client/private/httpbin.example.com.key.pem \
    https://httpbin.example.com:$SECURE_INGRESS_PORT/status/418

}

clean_up() {
  kubectl delete mutatingwebhookconfiguration --all
  kubectl delete validatingwebhookconfiguration --all
  kubectl delete psp --all
  kubectl delete daemonset --all
  kubectl delete deploy --all
  kubectl delete configmap --all
  kubectl delete service --all
  kubectl delete ingress --all
  kubectl delete namespace --all
  kubectl delete rule --all
  kubectl delete denier --all
  kubectl delete checknothing --all
  kubectl delete serviceaccount --all
  kubectl delete secret --all
  kubectl delete EgressRules --all
  kubectl delete MeshPolicy --all
  kubectl delete serviceentry --all
  kubectl delete virtualservice --all
  kubectl delete gateway --all
  kubectl delete destinationrule --all
  kubectl delete poddisruptionbudgets --all
}


install() {
  clean_up
  sleep 60
  install_controlplane
  sleep 60
  install_httpbin
  generate_certs
  configure_sds_gateway
}

####### Normal TLS #########
setup_tls_ingressgateway() {
  echo "Test TLS Ingress Gateway"
  install
  sleep 60
  get_ingressgateway
  setup_httpbin
  sleep 45
  verify_httpbin
}

####### Mutual TLS #########
setup_mtls_ingressgateway() {
  echo "Test MTLS Ingress Gateway"
  install
  sleep 60
  get_ingressgateway
  setup_httpbin_mtls
  sleep 45
  echo
  echo "#################### SHOULD FAIL ######################"
  verify_httpbin # Will fail
  echo
  echo "#################### SHOULD SUCCEED ######################"
  verify_httpbin_mtls
}

####### Mutual TLS with Hash verification #########
# This has issue now.
setup_mtls_with_hash_ingressgateway() {
  echo "Test TLS Ingress Gateway with hash verification"
  install
  sleep 60
  get_ingressgateway
  setup_httpbin_mtls_with_hash
  sleep 45
  verify_httpbin_mtls
}

clean_all() {
  echo "Clean up the files..."
  rm -rf istio-$VER/
  rm -rf httpbin.example.com/
  rm -rf mtls-go-example/
}

case "$1" in
  -t|--tls)
    setup_tls_ingressgateway
    ;;
  -m|--mtls)
    setup_mtls_ingressgateway
    ;;
  -h|--hash)
    setup_mtls_with_hash_ingressgateway
    ;;
  -c|--clean)
    clean_all
    ;;
  *)
    echo "Programming error"
    exit 3
    ;;
esac
