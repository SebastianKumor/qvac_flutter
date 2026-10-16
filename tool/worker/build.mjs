// Builds the QVAC worker and copies it, its native addons and BareKit into the
// plugin's ios/ and android/ folders. Run with `npm run build` (macOS for iOS).
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import link from 'bare-link'
import { bundleSdk } from '@qvac/sdk/commands'
import { writePackageSwift } from './package_swift.mjs'
import { licenseTexts } from './licenses.mjs'

const root = import.meta.dirname
const plugin = path.resolve(root, '../..')
const out = path.join(root, 'qvac')
const hosts = {
  ios: ['ios-arm64', 'ios-arm64-simulator'],
  android: ['android-arm64']
}
const barekit = {
  url: 'https://github.com/holepunchto/bare-kit/releases/download/v2.5.5/prebuilds.zip',
  sha256: 'fc68740347c8532ba49d45bf61fae9ca1f1040dc7d6c99f2f92dc30c40e84e46'
}
const onMac = process.platform === 'darwin'

// 1. Bundle the worker with only the plugins in qvac.config.json.
const result = await bundleSdk({
  projectRoot: root,
  hosts: onMac ? Object.values(hosts).flat() : hosts.android,
  installMissingPrebuilds: true
})
// Native hosts load the raw bundle; the .js file only wraps it in a string for Metro.
const wrapped = await readFile(result.bundlePath, 'utf8')
const bundle = JSON.parse(wrapped.slice(wrapped.indexOf('=') + 1).trim().replace(/;$/, ''))
console.log(`Bundle: ${(bundle.length / 1e6).toFixed(1)} MB, ${result.addons.length} addons`)

// 2. Link the native addons the bundle loads.
const entry = path.join(out, 'worker.entry.mjs')
for (const [platform, platformHosts] of Object.entries(hosts)) {
  if (platform === 'ios' && !onMac) {
    console.warn('Skipping iOS: bare-link signs frameworks with codesign, which needs macOS.')
    continue
  }
  const dir = path.join(out, platform, 'addons')
  await rm(dir, { recursive: true, force: true })
  for await (const _ of link(entry, { hosts: platformHosts, out: dir }));
}

// 3. Fetch BareKit once and check it against the pinned hash.
const cache = path.join(root, 'cache')
const zip = path.join(cache, 'bare-kit-prebuilds.zip')
if (!existsSync(zip)) {
  await mkdir(cache, { recursive: true })
  console.log(`Downloading ${barekit.url}`)
  const res = await fetch(barekit.url)
  if (!res.ok) throw new Error(`BareKit download failed: ${res.status}`)
  await writeFile(zip, Buffer.from(await res.arrayBuffer()))
}
const hash = createHash('sha256').update(await readFile(zip)).digest('hex')
if (hash !== barekit.sha256) {
  await rm(zip)
  throw new Error(`BareKit zip hash is ${hash}, expected ${barekit.sha256}. Deleted it; run again.`)
}
const unpacked = path.join(cache, 'bare-kit')
if (!existsSync(unpacked)) {
  execFileSync('unzip', ['-q', zip, 'ios/*', 'android/*', '-d', unpacked])
}

// 4. Copy everything into the plugin. These folders are git-ignored.
if (onMac) {
  const ios = path.join(plugin, 'ios', 'qvac_flutter')
  const frameworks = path.join(ios, 'Frameworks')
  await rm(frameworks, { recursive: true, force: true })
  await cp(path.join(out, 'ios', 'addons'), frameworks, { recursive: true })
  // V8 build. The smaller JavaScriptCore build can't load ES modules, and the worker is ESM.
  await cp(path.join(unpacked, 'ios', 'BareKit.xcframework'),
    path.join(frameworks, 'BareKit.xcframework'), { recursive: true })
  // BareKit ships no module map, so Swift can't import it. It's unsigned, so adding one is safe.
  for (const slice of ['ios-arm64', 'ios-arm64_x86_64-simulator']) {
    const modules = path.join(frameworks, 'BareKit.xcframework', slice, 'BareKit.framework', 'Modules')
    await mkdir(modules, { recursive: true })
    await writeFile(path.join(modules, 'module.modulemap'),
      'framework module BareKit {\n  umbrella header "BareKit.h"\n  export *\n  module * { export * }\n}\n')
  }
  const resources = path.join(ios, 'Sources', 'qvac_flutter', 'Resources')
  await mkdir(resources, { recursive: true })
  await writeFile(path.join(resources, 'worker.bundle'), bundle)
  await writePackageSwift('local')
  console.log(`iOS: ${(await readdir(frameworks)).length} frameworks in ${path.relative(plugin, frameworks)}. Package.swift now uses them; release.mjs switches it back.`)
}

const android = path.join(plugin, 'android')
const jniLibs = path.join(android, 'src', 'main', 'jniLibs')
await rm(jniLibs, { recursive: true, force: true })
await cp(path.join(out, 'android', 'addons'), jniLibs, { recursive: true })
for (const abi of await readdir(jniLibs)) {
  await cp(path.join(unpacked, 'android', 'bare-kit', 'jni', abi), path.join(jniLibs, abi), { recursive: true })
}
await mkdir(path.join(android, 'libs'), { recursive: true })
await cp(path.join(unpacked, 'android', 'bare-kit', 'classes.jar'), path.join(android, 'libs', 'bare-kit.jar'))
const assets = path.join(android, 'src', 'main', 'assets')
await mkdir(assets, { recursive: true })
await writeFile(path.join(assets, 'worker.bundle'), bundle)
console.log(`Android: ${(await readdir(path.join(jniLibs, 'arm64-v8a'))).length} libraries in ${path.relative(plugin, jniLibs)}`)

// 5. List every npm package inside the bundle, plus the native notices, for THIRD_PARTY_NOTICES.md.
const header = JSON.parse(bundle.split('\n')[1])
const names = new Set()
for (const file of Object.keys(header.resolutions ?? {})) {
  const match = file.match(/^\/node_modules\/((?:@[^/]+\/)?[^/]+)\//)
  if (match) names.add(match[1])
}
const rows = []
for (const name of [...names].sort()) {
  const pkg = JSON.parse(await readFile(path.join(root, 'node_modules', name, 'package.json'), 'utf8'))
  rows.push(`| ${name} | ${pkg.version} | ${pkg.license ?? 'see package'} |`)
}
const asrNotice = await readFile(path.join(root, 'node_modules', '@qvac', 'asr-ggml', 'NOTICE'), 'utf8')
await writeFile(path.join(plugin, 'THIRD_PARTY_NOTICES.md'), `# Third-party notices

Generated by tool/worker/build.mjs. Do not edit by hand.

The native binaries this plugin ships contain the software below. Each is
used under its own license, linked from the package's npm page.

## BareKit

[BareKit](https://github.com/holepunchto/bare-kit) 2.5.5, Apache-2.0. It
embeds the Bare runtime (Apache-2.0), V8 (BSD-3-Clause) and libuv (MIT).
Android builds also ship the NDK's libc++ (Apache-2.0 with LLVM exception).

## npm packages in the worker bundle

| Package | Version | License |
| --- | --- | --- |
${rows.join('\n')}

## @qvac/asr-ggml NOTICE

\`\`\`
${asrNotice.trim()}
\`\`\`

${await licenseTexts()}`)
console.log(`Notices: ${rows.length} packages in THIRD_PARTY_NOTICES.md`)
