FROM alpine:latest

WORKDIR /app

ENV CRYPTOGRAPHY_DONT_BUILD_RUST=1

# Prep base system
RUN set -e \
	&& ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime \
	&& apk --update add --no-cache \
		aws-cli \
		curl \
		docker \
		git \
		jq \
	&& rm -f /var/cache/apk/*

# Manage the Entrypoint
COPY entrypoint.sh ./
ENTRYPOINT ["/app/entrypoint.sh"]
