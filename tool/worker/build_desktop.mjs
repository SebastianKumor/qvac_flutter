// Builds the desktop worker and links its addons for macOS, Linux and Windows.
// Output goes to build_desktop/ in the plugin, where the Linux and Windows CMake
// files look first. release_desktop.mjs zips it. Run with `npm run build:desktop`.
import { execFileSync } from 'node:child_process'
import { cp, mkdir, readFile, readdir, rename, rm, symlink, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import link from 'bare-link'
import { bundleSdk } from '@qvac/sdk/commands'
import { writePackageSwift } from './package_swift.mjs'

const root = import.meta.dirname
const plugin = path.resolve(root, '../..')
const out = path.join(plugin, 'build_desktop')
// BareKit's macOS build is arm64 only, and asr-ggml has no Windows arm64 build.
const targets = {
  'macos-arm64': { host: 'darwin-arm64', barekit: 'darwin/BareKit.xcframework' },
  'linux-x64': { host: 'linux-x64', barekit: 'linux/x64/libbare-kit.so' },
  'linux-arm64': { host: 'linux-arm64', barekit: 'linux/arm64/libbare-kit.so' },
  'windows-x64': { host: 'win32-x64', barekit: 'win32/x64/bare-kit.dll' }
}

const result = await bundleSdk({
  projectRoot: root,
  hosts: Object.values(targets).map((t) => t.host),
  installMissingPrebuilds: false
})
const wrapped = await readFile(result.bundlePath, 'utf8')
const bundle = JSON.parse(wrapped.slice(wrapped.indexOf('=') + 1).trim().replace(/;$/, ''))
console.log(`Bundle: ${(bundle.length / 1e6).toFixed(1)} MB, ${result.addons.length} addons`)

const zip = path.join(root, 'cache', 'bare-kit-prebuilds.zip')
if (!existsSync(zip)) throw new Error('Run `npm run build` first, it fetches and checks BareKit.')
const unpacked = path.join(root, 'cache', 'bare-kit')
for (const t of Object.values(targets)) {
  if (!existsSync(path.join(unpacked, t.barekit))) {
    execFileSync('unzip', ['-q', '-o', zip, `${t.barekit}*`, '-d', unpacked], { stdio: 'ignore' })
  }
}

await rm(out, { recursive: true, force: true })
const entry = path.join(root, 'qvac', 'worker.entry.mjs')
for (const [name, t] of Object.entries(targets)) {
  const dir = path.join(out, name)
  for await (const _ of link(entry, { hosts: [t.host], out: dir }));
  await cp(path.join(unpacked, t.barekit), path.join(dir, path.basename(t.barekit)), { recursive: true })
  // Linux: addons in one folder, which Dart loads from. ggml looks for its CPU
  // and Vulkan backends in <backendsDir>/<host>/qvac__asr-ggml instead.
  if (existsSync(path.join(dir, 'lib'))) {
    const backends = path.join(dir, 'backends', t.host, 'qvac__asr-ggml')
    await mkdir(backends, { recursive: true })
    for (const f of await readdir(path.join(dir, 'lib'))) {
      const to = f.startsWith('libqvac-speech-ggml-') ? path.join(backends, f) : path.join(dir, f)
      await rename(path.join(dir, 'lib', f), to)
    }
    await rm(path.join(dir, 'lib'), { recursive: true })
  }
  await writeFile(path.join(dir, 'worker.bundle'), bundle)
  console.log(`${name}: ${(await readdir(dir)).length} files`)
}

// macOS: SwiftPM needs xcframeworks, and the Swift target ships the bundle as a resource.
const macos = path.join(plugin, 'macos', 'qvac_flutter')
const frameworks = path.join(macos, 'Frameworks')
await rm(frameworks, { recursive: true, force: true })
await mkdir(frameworks, { recursive: true })
const mac = path.join(out, 'macos-arm64')
for (const f of await readdir(mac)) {
  if (!f.endsWith('.framework')) continue
  execFileSync('xcodebuild', ['-create-xcframework', '-framework', path.join(mac, f),
    '-output', path.join(frameworks, f.replace(/\.framework$/, '.xcframework'))], { stdio: 'ignore' })
}
// BareKit's zip has copies where symlinks belong, and a universal top-level binary
// next to the arm64 one in Versions/A. Rebuild the framework around Versions/A,
// so the xcframework says arm64 only, which is what every addon is too.
const staging = path.join(root, 'cache', 'BareKit-macos')
const fw = path.join(staging, 'BareKit.framework')
await rm(staging, { recursive: true, force: true })
await cp(path.join(mac, 'BareKit.xcframework', 'macos-arm64_x86_64', 'BareKit.framework', 'Versions', 'A'),
  path.join(fw, 'Versions', 'A'), { recursive: true })
await symlink('A', path.join(fw, 'Versions', 'Current'))
for (const name of ['BareKit', 'Headers', 'Resources']) {
  await symlink(path.join('Versions', 'Current', name), path.join(fw, name))
}
execFileSync('xcodebuild', ['-create-xcframework', '-framework', fw,
  '-output', path.join(frameworks, 'BareKit.xcframework')], { stdio: 'ignore' })
const resources = path.join(macos, 'Sources', 'qvac_flutter', 'Resources')
await mkdir(resources, { recursive: true })
await writeFile(path.join(resources, 'worker.bundle'), bundle)
await writePackageSwift('local', 'macos')
console.log(`macOS: ${(await readdir(frameworks)).length} frameworks in macos/qvac_flutter/Frameworks`)
