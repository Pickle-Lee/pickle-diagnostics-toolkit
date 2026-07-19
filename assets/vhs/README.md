# Regenerating the terminal gif

The README's terminal gif (`assets/demo.gif`) is rendered with
[VHS](https://github.com/charmbracelet/vhs).

Because the toolkit is Windows-only, VHS (which runs Linux) can't execute the
real script. Instead `demo.tape` types the usual command against `verdict.sh` -
a shim that prints `diagnostic.ps1`'s genuine verdict output. The text/colors
are real tool output; the run itself is illustrative, not a live capture.

## Render (requires Docker)

```bash
cd assets/vhs
docker run --rm -v "$(pwd):/vhs" ghcr.io/charmbracelet/vhs demo.tape
mv demo.gif ../demo.gif
```

On Windows Git Bash, the mount path needs Windows form and no MSYS conversion:

```bash
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/vhs" ghcr.io/charmbracelet/vhs demo.tape
```

## Files

- `demo.tape`  - the VHS script (timings, theme, typed command)
- `verdict.sh` - shim that reproduces the terminal verdict output
