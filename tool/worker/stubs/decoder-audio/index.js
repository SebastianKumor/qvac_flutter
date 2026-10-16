// Only compressed files (.mp3, .m4a, ...) reach this. Send 16 kHz mono PCM instead.
class FFmpegDecoder {
  async load () {
    throw new Error('qvac_flutter is built without FFmpeg, so it cannot decode compressed audio files. Send 16 kHz mono PCM.')
  }

  async unload () {}
}

module.exports = { FFmpegDecoder }
