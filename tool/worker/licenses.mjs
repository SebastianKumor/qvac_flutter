// Full license texts for the C and C++ code inside the native binaries.
import { readFile, readdir } from 'node:fs/promises'
import path from 'node:path'

const dir = path.join(import.meta.dirname, 'licenses')

export async function licenseTexts() {
  const parts = []
  for (const file of (await readdir(dir)).filter((f) => f.endsWith('.txt')).sort()) {
    const text = await readFile(path.join(dir, file), 'utf8')
    parts.push(`### ${file.replace(/\.txt$/, '')}\n\n\`\`\`\n${text.trim()}\n\`\`\``)
  }
  return `## License texts

RocksDB is used under Apache-2.0, as are Bare and BareKit. That text is in
LICENSE. RocksDB includes LZ4, Snappy and zstd. bare-crypto and bare-tls
include BoringSSL. whisper.cpp runs on ggml.

${parts.join('\n\n')}
`
}
