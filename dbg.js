const fs = require("fs");
const { JSDOM } = require("jsdom");
const dom = new JSDOM("<!DOCTYPE html><html><body></body></html>", { pretendToBeVisual: true });
Object.assign(global, { window: dom.window, document: dom.window.document, navigator: dom.window.navigator, HTMLElement: dom.window.HTMLElement, DOMParser: dom.window.DOMParser, NodeFilter: dom.window.NodeFilter, Node: dom.window.Node, Element: dom.window.Element, SVGElement: dom.window.SVGElement, getComputedStyle: dom.window.getComputedStyle });
const md = fs.readFileSync(process.argv[2], "utf8");
const re = /```mermaid\n([\s\S]*?)\n```/g; let m, i=0;
(async () => {
  const mm = require("mermaid"); const mermaid = mm.default || mm;
  mermaid.initialize({ startOnLoad: false, securityLevel: "loose" });
  while ((m = re.exec(md)) !== null) { i++;
    if (i !== 3) continue;
    console.log("=== BLOCK 3 LINE 13 ===");
    console.log(m[1].split("\n").slice(10, 16).map((l, n) => (n + 11) + ": " + l).join("\n"));
    try { await mermaid.parse(m[1]); console.log("VALID"); }
    catch (e) { console.log("\nERROR:\n" + e.message.slice(0, 600)); }
  }
})();