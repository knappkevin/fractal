import QtQuick
import Quickshell.Io

// The background-picker image: the picture the switcher offers for this plugin.
//
// It is rendered rather than shipped. A still baked into the plugin is a picture
// of one point in one theme, so on any other theme it is simply wrong -- and it
// was being seen, because the renderer used to run only when the effect was on
// screen, which is exactly not the case after a theme switch.
//
// So the shipped still is a last resort only, never a placeholder: the directory
// is created, the render writes straight into it, and the still is copied in only
// if the render cannot run at all.
QtObject {
  id: thumb

  property string home: ""
  property string pluginDir: ""
  property string stateDir: ""     // holds theme/backgrounds
  property string fileName: ""     // e.g. fractal-zoom.png
  property string seedScript: ""   // copied from, as the last resort

  // Commands are handed the output path, so a caller only has to know how to
  // render, not where the result goes.
  readonly property string outputPath: stateDir + "/theme/backgrounds/" + fileName

  // A request that arrives while a render is in flight waits for it rather than
  // being dropped: a theme switch and a point switch together are two renders,
  // and the second is the one that matters.
  property bool wanted: false
  property var nextCommand: []

  function request(command) {
    nextCommand = command
    wanted = true
    pump()
  }

  function pump() {
    if (!wanted || render.running || prepare.running)
      return
    if (!nextCommand.length)
      return
    wanted = false
    // The theme directory is replaced wholesale on a switch, so its backgrounds
    // subdirectory may not exist yet.
    prepare.running = true
  }

  // Runs first: the renderer cannot write into a directory that is not there.
  property Process prepare: Process {
    clearEnvironment: true
    environment: ({ HOME: thumb.home })
    command: ["/usr/bin/mkdir", "-p", thumb.stateDir + "/theme/backgrounds"]
    onExited: function(code) {
      if (code !== 0) {
        thumb.seed()
        return
      }
      render.command = ["/usr/bin/timeout", "-k", "5", "90"].concat(thumb.nextCommand)
      render.running = true
    }
  }

  property Process render: Process {
    clearEnvironment: true
    environment: ({ HOME: thumb.home })
    onExited: function(code) {
      if (code === 0) {
        thumb.pump()
        return
      }
      // 124 and 143 are the timeout wrapper giving up on us.
      if (code !== 143 && code !== 124)
        console.warn("fractal: thumbnail render exited " + code
                     + "; falling back to the shipped still")
      // No python3, or a point file that has gone missing. A picture of
      // another theme beats no entry in the picker at all.
      thumb.seed()
    }
  }

  property Process seeder: Process {
    clearEnvironment: true
    environment: ({ HOME: thumb.home })
    onExited: function(code) {
      if (code !== 0)
        console.warn("fractal: " + thumb.seedScript + " exited " + code
                     + "; the effect will not appear in the background picker")
      // Only reached when the render could not run.
      thumb.pump()
    }
  }

  function seed() {
    if (seeder.running)
      return
    seeder.command = ["/usr/bin/timeout", "-k", "5", "30",
                      "/usr/bin/bash", seedScript, "install", pluginDir]
    seeder.running = true
  }
}
