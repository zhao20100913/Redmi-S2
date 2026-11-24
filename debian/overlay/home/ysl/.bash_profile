# tty1 is the phone screen: log in and start Denial there.  ssh, serial and
# ttyGS0 keep a normal shell.
if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && [ -z "${WAYLAND_DISPLAY:-}" ] \
	&& [ -z "${YSL_SESSION_STARTED:-}" ]; then
	export YSL_SESSION_STARTED=1
	if command -v denial-session >/dev/null 2>&1; then
		exec /usr/local/bin/ysl-start-denial
	fi
	exec /bin/bash -l
fi
