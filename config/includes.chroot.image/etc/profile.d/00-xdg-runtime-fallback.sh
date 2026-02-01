# Fallback XDG_RUNTIME_DIR when pam_systemd fails
if [ -z "$XDG_RUNTIME_DIR" ]; then
    _uid=$(id -u)
    export XDG_RUNTIME_DIR="/run/user/$_uid"
    if [ ! -d "$XDG_RUNTIME_DIR" ]; then
        mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null
        chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
    fi
    unset _uid
fi
