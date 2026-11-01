// asm.catch.mjs — catch 游戏的极简汇编器（改游戏就改下面的 SRC，然后 node asm.catch.mjs）
import fs from 'node:fs';

const SRC = `
  JP main
sprite_ball:
  db 0x80
sprite_paddle:
  db 0xFF
main:
  LD V0, 24
  LD V5, 30
  LD V9, 31
  LD V3, 0
  CALL newball
loop:
  CLS
  LD I, sprite_paddle
  DRW V0, V5, 1
  LD I, sprite_ball
  DRW V1, V2, 1
  LD V7, 0
scoredraw:
  SNE V7, V3
  JP scoredone
  LD I, sprite_ball
  DRW V7, V9, 1
  ADD V7, 1
  JP scoredraw
scoredone:
  LD V6, 4
  SKNP V6
  CALL left
  LD V6, 7
  SKNP V6
  CALL left
  LD V6, 6
  SKNP V6
  CALL right
  LD V6, 9
  SKNP V6
  CALL right
  LD V6, 2
  LD DT, V6
wait:
  LD V6, DT
  SE V6, 0
  JP wait
  ADD V2, 1
  SE V2, 30
  JP loop
  LD I, sprite_paddle
  DRW V0, V5, 1
  LD I, sprite_ball
  DRW V1, V5, 1
  SE VF, 1
  JP miss
  ADD V3, 1
  CALL newball
  JP loop
miss:
  LD V3, 0
  CALL newball
  JP loop
newball:
  RND V1, 0x3F
  LD V2, 0
  RET
left:
  SE V0, 0
  JP left2
  RET
left2:
  LD V6, 8
  SUB V0, V6
  RET
right:
  LD V6, 56
  SE V0, V6
  JP right2
  RET
right2:
  ADD V0, 8
  RET
`;

const lines = SRC.split(/\r?\n/).map((l) => l.replace(/;.*$/, '').trim()).filter(Boolean);
let addr = 0x200;
const labels = {};
const items = [];
for (const line of lines) {
  const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*):$/);
  if (m) { labels[m[1]] = addr; continue; }
  if (line.startsWith('db ')) { items.push({ db: Number(line.slice(3)), at: addr }); addr += 1; continue; }
  items.push({ text: line, at: addr });
  addr += 2;
}
const V = (s) => parseInt(s.slice(1), 16);
const val = (s) => (labels[s] !== undefined ? labels[s] : (/^0x[0-9a-f]+$/i.test(s) ? parseInt(s, 16) : Number(s)));
const B = (s) => val(s) & 0xff;

const out = [];
for (const it of items) {
  if (it.db !== undefined) { out.push(it.db & 0xff); continue; }
  const parts = it.text.split(/\s+/);
  const mn = parts[0];
  const args = parts.slice(1).join(' ').split(/\s*,\s*/);
  let w = 0;
  switch (mn) {
    case 'CLS': w = 0x00E0; break;
    case 'RET': w = 0x00EE; break;
    case 'JP': w = 0x1000 | (val(args[0]) & 0xfff); break;
    case 'CALL': w = 0x2000 | (val(args[0]) & 0xfff); break;
    case 'SE':
      w = (args.length === 2 && /^0x|^\d/.test(args[1]) === false && !/^0x/.test(args[1]))
        ? 0x5000 | (V(args[0]) << 8) | (V(args[1]) << 4)
        : 0x3000 | (V(args[0]) << 8) | B(args[1]);
      break;
    case 'SNE':
      w = /^V/.test(args[1])
        ? 0x9000 | (V(args[0]) << 8) | (V(args[1]) << 4)
        : 0x4000 | (V(args[0]) << 8) | B(args[1]);
      break;
    case 'LD':
      if (args[0] === 'I') { w = 0xA000 | (val(args[1]) & 0xfff); break; }
      if (args[0] === 'DT') { w = 0xF000 | (V(args[1]) << 8) | 0x15; break; }
      if (args[0] === 'B') { w = 0xF000 | (V(args[1]) << 8) | 0x33; break; }
      if (args[0] === 'F') { w = 0xF000 | (V(args[1]) << 8) | 0x29; break; }
      if (args[0] === '[I]') { w = 0xF000 | (V(args[1]) << 8) | 0x55; break; }
      w = /^V/.test(args[1])
        ? 0x8000 | (V(args[0]) << 8) | (V(args[1]) << 4)
        : 0x6000 | (V(args[0]) << 8) | B(args[1]);
      break;
    case 'ADD':
      if (args[0] === 'I') { w = 0xF000 | (V(args[1]) << 8) | 0x1E; break; }
      w = /^V/.test(args[1])
        ? 0x8000 | (V(args[0]) << 8) | (V(args[1]) << 4) | 0x4
        : 0x7000 | (V(args[0]) << 8) | B(args[1]);
      break;
    case 'SUB': w = 0x8000 | (V(args[0]) << 8) | (V(args[1]) << 4) | 0x5; break;
    case 'OR': w = 0x8000 | (V(args[0]) << 8) | (V(args[1]) << 4) | 0x1; break;
    case 'AND': w = 0x8000 | (V(args[0]) << 8) | (V(args[1]) << 4) | 0x2; break;
    case 'XOR': w = 0x8000 | (V(args[0]) << 8) | (V(args[1]) << 4) | 0x3; break;
    case 'DRW': w = 0xD000 | (V(args[0]) << 8) | (V(args[1]) << 4) | (Number(args[2]) & 0xf); break;
    case 'RND': w = 0xC000 | (V(args[0]) << 8) | B(args[1]); break;
    case 'SKNP': w = 0xE000 | (V(args[0]) << 8) | 0xA1; break;
    case 'SKP': w = 0xE000 | (V(args[0]) << 8) | 0x9E; break;
    default: throw new Error('未知指令: ' + it.text);
  }
  out.push((w >> 8) & 0xff, w & 0xff);
}
const buf = Buffer.from(out);
fs.writeFileSync(new URL('./roms/catch.ch8', import.meta.url), buf);
console.log('catch.ch8', buf.length, 'bytes');
