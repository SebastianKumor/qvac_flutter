// Fixes in @qvac/inference that the worker bundle needs. Each edit runs once and fails the
// build if the SDK code it expects is gone, so an SDK update can't skip one silently.
import { readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'

const file = path.join(import.meta.dirname, 'node_modules/@qvac/inference/dist/handlers/load-model/http.js')
const applied = '// qvac_flutter: complete marker'

// Offline, 0.21.0 only trusts a cached model with a GGUF header, so a Whisper .bin
// downloaded by URL fails to load. A `.complete` file written after the download fixes it.
const edits = [
  {
    // Lets the offline check accept a file that a finished download marked.
    find: `            logger.info(\`📴 Falling back to GGUF header validation...\`);\n`,
    replace: `            ${applied}
            if (await isMarkedComplete(modelPath, localSize)) {
                logger.info(\`✅ Offline - download marked complete, using cached file: \${modelPath}\`);
                return modelPath;
            }
            logger.info(\`📴 Falling back to GGUF header validation...\`);\n`
  },
  {
    // A cache that the server's size confirms gets a marker too, for files from before this fix.
    find: `        logger.info(\`✅ Using cached HTTP model: \${modelPath}\`);\n`,
    replace: `        await markComplete(modelPath, localSize);
        logger.info(\`✅ Using cached HTTP model: \${modelPath}\`);\n`
  },
  {
    // The old marker goes before a new download, and a new one comes after it is checked.
    find: `            ctx.setCacheHit(false);
            const meta = await performHttpDownloadWithResume(url, modelPath, downloadKey, requireSecureTransport, ctx.broadcastProgress, ctx.signal);
            await verifyHttpModelFile(url, modelPath, meta.hubSha256, requireChecksum, hooks);\n`,
    replace: `            ctx.setCacheHit(false);
            await fsPromises.unlink(completeMarker(modelPath)).catch(() => { });
            const meta = await performHttpDownloadWithResume(url, modelPath, downloadKey, requireSecureTransport, ctx.broadcastProgress, ctx.signal);
            await verifyHttpModelFile(url, modelPath, meta.hubSha256, requireChecksum, hooks);
            await markComplete(modelPath, (await fsPromises.stat(modelPath)).size);\n`
  },
  {
    find: `function extractFilenameFromUrl(url) {\n`,
    replace: `const completeMarker = (modelPath) => \`\${modelPath}.complete\`;
async function markComplete(modelPath, size) {
    try {
        await fsPromises.writeFile(completeMarker(modelPath), String(size));
    }
    catch (error) {
        logger.warn(\`⚠️ Could not mark download complete: \${error instanceof Error ? error.message : String(error)}\`);
    }
}
async function isMarkedComplete(modelPath, size) {
    try {
        return String(await fsPromises.readFile(completeMarker(modelPath), 'utf8')).trim() === String(size);
    }
    catch {
        return false;
    }
}
function extractFilenameFromUrl(url) {\n`
  }
]

export async function applyPatches () {
  let source = await readFile(file, 'utf8')
  if (source.includes(applied)) return
  for (const { find, replace } of edits) {
    if (source.split(find).length !== 2) {
      throw new Error(`patches.mjs: expected code not found once in ${file}:\n${find}`)
    }
    source = source.replace(find, () => replace)
  }
  await writeFile(file, source)
  console.log('Patched @qvac/inference: offline load of models downloaded by URL')
}
