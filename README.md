# Fractal Wallpaper + Screensaver Plugin for Omarchy

An infinite zoom into a fractal, colored by your theme. Features Misiurewicz points from the Mandelbrot set and the higher-degree
Multibrots, with a Julia set at each one. Not very lightweight.

## Install

```sh
omarchy plugin add https://github.com/knappkevin/fractal.git --enable
```

`Super + Ctrl + Space` to pick it from the wallpaper picker. Double click to open its settings.

<table>
<tr>
<td><img src="assets/lightning.png" width="380" alt="lightning"></td>
<td><img src="assets/snowflake.png" width="380" alt="snowflake"></td>
</tr>
<tr>
<td><img src="assets/bramble.png" width="380" alt="bramble"></td>
<td><img src="assets/dragon.png" width="380" alt="dragon"></td>
</tr>
</table>

## Runtime IPC

```sh
omarchy-shell fractal help               # lists some more unneeded commands
omarchy-shell fractal menu               # alternative to double clicking for settings
```

## Remove

```sh
omarchy plugin remove knappkevin.fractal
```
