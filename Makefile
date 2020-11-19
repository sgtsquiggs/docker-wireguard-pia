IMAGE=sgtsquiggs/wireguard-pia

.PHONY: build
build:
	sh build.sh "$(IMAGE)"

.PHONY: push
push:
	sh push.sh "$(IMAGE)"
