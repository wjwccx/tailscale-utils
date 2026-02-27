FROM alpine:3.17

RUN apk update && apk upgrade \
    && apk add --no-cache bash curl jq util-linux docker-cli iptables
RUN apk add --no-cache traceroute

CMD "sleep infinity"
