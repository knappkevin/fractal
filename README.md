# Fractal Wallpaper Plugin for Omarchy

An infinite zoom into a fractal, drawn in the colors of your active theme. Features 12 different Misiurewicz points in the Mandelbrot set. Pick it from the background switcher like any other wallpaper. Not very lightweight.

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

## Install

```sh
omarchy plugin add https://github.com/knappkevin/fractal.git --enable
```

`Super + Ctrl + Space` to pick it from the wallpaper picker.

## Runtime IPC

```sh
omarchy-shell fractal help               # every command, with what it does
omarchy-shell fractal pause toggle       # pause the animation
omarchy-shell fractal point random       # jump to another zoom point
omarchy-shell fractal point list         # the zoom points available
omarchy-shell fractal point x            # zoom into point x from the list
omarchy-shell fractal fps 20             # how many frames a second to draw
omarchy-shell fractal speed 0.03         # octaves of zoom per second
omarchy-shell fractal refresh            # re-read the theme, remake the picker image
```

## Remove

```sh
omarchy plugin remove knappkevin.fractal
```
