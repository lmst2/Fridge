# Test runner: busted on Lua 5.2, the Lua version Factorio embeds.
# The mod is mounted at /mod rather than copied, so the image only changes
# when the toolchain does. See spec/run.sh.
FROM alpine:3.20

RUN apk add --no-cache lua5.2 lua5.2-dev luarocks5.2 build-base \
 && luarocks-5.2 install busted 2.3.0-1

WORKDIR /mod
ENTRYPOINT ["busted"]
