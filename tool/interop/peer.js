// Stand-in for the QVAC worker, using the real bare-rpc package.
// Usage: node peer.js <port>. Connects to the Dart test like the worker does.
const net = require('net')
const RPC = require('bare-rpc')

const socket = net.connect(Number(process.argv[2]), '127.0.0.1')

new RPC(socket, async (req) => {
  const msg = JSON.parse(req.data.toString())
  switch (msg.type) {
    case 'echo':
      return req.reply(JSON.stringify({ type: 'echo', got: msg }), 'utf-8')
    case 'qvacError':
      return req.reply(JSON.stringify({ type: 'error', message: 'no such model', code: 52404 }), 'utf-8')
    case 'throw':
      throw new Error('handler blew up')
    case 'count': {
      const out = req.createResponseStream()
      // Cut the lines at odd places, like a real worker writing tokens.
      let text = ''
      for (let i = 0; i < msg.n; i++) text += JSON.stringify({ type: 'count', i }) + '\n'
      text += JSON.stringify({ type: 'count', done: true }) + '\n'
      for (let at = 0; at < text.length; at += 7) out.write(Buffer.from(text.slice(at, at + 7)))
      return out.end()
    }
    case 'big':
      return req.reply(JSON.stringify({ type: 'big', text: 'ä'.repeat(msg.n) }), 'utf-8')
    case 'bye':
      req.reply(JSON.stringify({ type: 'bye' }), 'utf-8')
      return setTimeout(() => socket.end(), 50)
  }
})
