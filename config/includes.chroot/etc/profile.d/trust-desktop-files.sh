# Mark desktop files as trusted on first login (KDE Plasma)
if [ -d "$HOME/Desktop" ] && command -v gio >/dev/null 2>&1; then
    for f in "$HOME/Desktop"/*.desktop; do
        [ -f "$f" ] && gio set "$f" metadata::trusted true 2>/dev/null
    done
fi
