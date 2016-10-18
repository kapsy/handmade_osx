# Handmade Hero OSX

This is my OSX Platform Layer implementation of Casey Muratoris excellent [Handmade Hero](https://handmadehero.org) series.

While there are a number of other very good OSX implementations out there, I thought it would be great for a beginner to the series to have as many different implementations as possible to refer to, especially if they present different solutions for the same problem.

# Notes

Covers up until and including Episode 52.

This is a work in progress, and in the spirit of the series, much of the functionality is in a malleable working state, and would be quite different to that of the final, shippable game.

Does not include any game source. The source can be purchased for $15 at [https://handmadehero.org].

There is no Game Pad input support as of yet, as I don't own a Game Pad, but support is planned for a future update.

There is a ring buffer for the audio to allow writing more bytes per frame that the IOProc callback's buffer can handle. This is to both emulate how the Windows Platform Layer handles audio, and to provide an easy way to sync with screen updates.

A big thanks to Jeff Buck for his [OSX implementation](https://github.com/itfrombit/osx_handmade), which helped a great deal in a number of areas where I got stuck.

If you're a beginner to the series and would like to follow with OSX, then I thoroughly recommend using this repository (and the other excellent OSX implementations out there) as a guide, implementing everything yourself from first principles. There is a great deal to be learned, and it is very much worth it if you plan on using OSX as a Platform for other future projects.
