# Try Omarchy's per-app wrappers (Ghostty on the software renderer) come
# before /usr/bin. Omarchy's session takes PATH from this login shell.
case ":$PATH:" in
  *:/usr/lib/try-omarchy/bin:*) ;;
  *) PATH="/usr/lib/try-omarchy/bin:$PATH" ;;
esac
