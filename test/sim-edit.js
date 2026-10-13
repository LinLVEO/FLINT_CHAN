// sim-edit.js — 模拟编辑器 keydown 核心逻辑（DOM 无关，验证自动缩进/收尾）
// 用法: node test/sim-edit.js
"use strict";

// —— 复刻 app.js 的纯逻辑（从 keydown handler 提炼）——
function currentIndentOf(v, s) {
  const lineStart = v.lastIndexOf("\n", s - 1) + 1;
  let n = 0;
  for (let i = lineStart; i < s; i++) {
    if (v[i] === " ") n++;
    else if (v[i] === "\t") n += 2;
    else break;
  }
  return n;
}
function linePrefixOf(v, s) {
  const lineStart = v.lastIndexOf("\n", s - 1) + 1;
  return v.slice(lineStart, s);
}
function lineStartIdxOf(v, s) {
  return v.lastIndexOf("\n", s - 1) + 1;
}
function nextNonSpaceIdxOf(v, s) {
  let i = s;
  while (i < v.length && (v[i] === " " || v[i] === "\t" || v[i] === "\n")) i++;
  return i < v.length ? i : -1;
}
const indentStr = (n) => " ".repeat(Math.max(0, n));

// 模拟：输入单字符 / 回车
function type(state, ch) {
  let { v, s } = state;
  const insert = (text, caretOffset) => {
    const pos = s + (caretOffset === undefined ? text.length : caretOffset);
    return { v: v.slice(0, s) + text + v.slice(s), s: pos };
  };

  if (ch === "\n") {
    const base = currentIndentOf(v, s);
    const prefix = linePrefixOf(v, s).replace(/\s+$/, "");
    let next = base;
    if (prefix.endsWith("{")) next = base + 2;
    else if (prefix.endsWith("}") || prefix.endsWith(")")) next = Math.max(0, base - 2);
    return insert("\n" + indentStr(next), 1 + next);
  }
  // 右括号跳过
  if (ch === ")" || ch === "]" || ch === "}") {
    const prefixTrim = linePrefixOf(v, s).trim();
    const j = nextNonSpaceIdxOf(v, s);
    if (j >= 0 && v[j] === ch) {
      if (ch === "}" && prefixTrim === "") {
        const ls = lineStartIdxOf(v, s);
        return { v: v.slice(0, ls) + v.slice(j), s: ls + 1 }; // 删空行，保留自动 }，光标到 } 后
      }
      return { v, s: j + 1 };
    }
    return insert(ch, 1);
  }
  // 左括号补全
  const OPEN_CLOSE = { "(": ")", "[": "]", "{": "}" };
  if (OPEN_CLOSE[ch]) {
    const close = OPEN_CLOSE[ch];
    if (ch === "{") {
      const base = currentIndentOf(v, s);
      const inner = indentStr(base + 2);
      return insert("{\n" + inner + "\n" + indentStr(base) + "}", 2 + inner.length);
    }
    return insert(ch + close, 1);
  }
  return insert(ch, 1);
}

let pass = 0, fail = 0;
function check(name, cond, extra = "") {
  if (cond) { pass++; console.log(`  ✅ ${name}`); }
  else { fail++; console.log(`  ❌ ${name} ${extra}`); }
}

// —— 场景 1：int main() { 后回车 → 2 空格 ——
{
  let st = { v: "", s: 0 };
  for (const c of "int main() ") st = type(st, c);
  st = type(st, "{");            // 块展开 → 光标在内容行(2空格)
  st = type(st, "\n");           // 空行回车（之前 bug：会变 4 空格）
  const line2 = st.v.split("\n")[1];
  check("块展开后空行回车 = 2 空格缩进", line2 === "  ", JSON.stringify(line2));
}

// —— 场景 2：内容行写 return 42; 再回车 → 新行保持 2 空格 ——
{
  let st = { v: "", s: 0 };
  for (const c of "int main() ") st = type(st, c);
  st = type(st, "{");            // 展开，光标已在内容行
  for (const c of "return 42;") st = type(st, c);  // 直接输入内容
  st = type(st, "\n");           // 写完回车
  const lines = st.v.split("\n");
  check("内容行后回车新行 = 2 空格", lines[2] === "  ", JSON.stringify(lines[2]));
}

// —— 场景 3：内容后空行输 } → 收尾删空行 ——
{
  let st = { v: "", s: 0 };
  for (const c of "int main() ") st = type(st, c);
  st = type(st, "{");
  for (const c of "return 42;") st = type(st, c);
  st = type(st, "\n");           // 换到空行准备收尾
  st = type(st, "}");            // 空行输 } → 删空行吃自动 }
  const text = st.v;
  check("收尾后无残留空行+重复}", text === "int main() {\n  return 42;\n}", text.replace(/\n/g, "\\n"));
}

// —— 场景 4：括号内输 ) 跳过自动补 ——
{
  // 模拟：v="foo(" 光标在 ( 后，自动补过 )，再输 ) 应跳过
  let st = { v: "foo(", s: 4 };
  st = type(st, ")");
  check("输 ) 跳过自动补，无重复", st.v === "foo()", st.v);
}

// —— 场景 5：嵌套 { 回车缩进递进 ——
{
  let st = { v: "", s: 0 };
  for (const c of "int main() ") st = type(st, c);
  st = type(st, "{");            // 光标内容行 2 空格
  for (const c of "for (int i = 0; i < 3; i = i + 1) ") st = type(st, c);
  st = type(st, "{");            // 嵌套块展开 → 光标 4 空格
  st = type(st, "\n");           // 回车应保持 4 空格
  const lines = st.v.split("\n");
  check("嵌套 for 块内回车 = 4 空格", lines[2] === "    ", JSON.stringify(lines[2]));
}

console.log(`----\n通过 ${pass} / 失败 ${fail}`);
process.exit(fail > 0 ? 1 : 0);
