// Packs the built native binaries for a GitHub release. Run after `npm run build`.
// Writes dist/<tag>/*.zip and the release.json files the plugin downloads from.
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { writePackageSwift } from './package_swift.mjs'

const root = import.meta.dirname
const plugin = path.resolve(root, '../..')
const pubspec = await readFile(path.join(plugin, 'pubspec.yaml'), 'utf8')
const repo = pubspec.match(/^repository:\s*https:\/\/github\.com\/(\S+)/m)[1]
// Its own tag, so a Dart-only release doesn't re-upload 88 MB. Bump it when the binaries change.
const tag = 'binaries-1'
const base = `https://github.com/${repo}/releases/download/${tag}`
const dist = path.join(root, 'dist', tag)
await rm(dist, { recursive: true, force: true })
await mkdir(dist, { recursive: true })

// iOS: one zip per xcframework, as Swift Package Manager binary targets need.
const frameworks = path.join(plugin, 'ios', 'qvac_flutter', 'Frameworks')
const ios = []
for (const file of (await readdir(frameworks)).filter((f) => f.endsWith('.xcframework')).sort()) {
  const zip = `${file}.zip`
  // No resource forks or xattrs: SwiftPM unzips them as ._ files, which breaks the signature.
  execFileSync('ditto', ['-c', '-k', '--norsrc', '--noextattr', '--noacl', '--keepParent',
    path.join(frameworks, file), path.join(dist, zip)])
  const checksum = execFileSync('swift', ['package', 'compute-checksum', path.join(dist, zip)]).toString().trim()
  ios.push({ file, url: `${base}/${zip}`, checksum })
}
await writeFile(path.join(plugin, 'ios', 'qvac_flutter', 'release.json'), JSON.stringify(ios, null, 2) + '\n')
await writePackageSwift('release')

// Android: the .so files and BareKit's classes in one zip.
const android = path.join(plugin, 'android')
const zip = 'android-arm64.zip'
execFileSync('zip', ['-q', '-r', path.join(dist, zip), 'src/main/jniLibs', 'libs/bare-kit.jar'], { cwd: android })
const sha256 = createHash('sha256').update(await readFile(path.join(dist, zip))).digest('hex')
await writeFile(path.join(android, 'release.json'), JSON.stringify({ url: `${base}/${zip}`, sha256 }, null, 2) + '\n')

console.log(`Packed ${ios.length + 1} files into ${path.relative(plugin, dist)}`)
console.log(`Upload them with: gh release create ${tag} ${path.relative(plugin, dist)}/* --repo ${repo} --title ${tag}`)
