interface MdInline {
  text: string;
  bold: boolean;
  code: boolean;
}

interface MdBlock {
  kind: string;
  text: string;
  level: number;
}

function parseInline(text: string): MdInline[] {
  const segs: MdInline[] = [];
  let buf: string = '';
  let i: number = 0;
  const flush = (): void => {
    if (buf.length > 0) {
      segs.push({ text: buf, bold: false, code: false });
      buf = '';
    }
  };
  while (i < text.length) {
    if (text.startsWith('**', i)) {
      const end = text.indexOf('**', i + 2);
      if (end > i + 2) {
        flush();
        segs.push({ text: text.substring(i + 2, end), bold: true, code: false });
        i = end + 2;
        continue;
      }
    }
    const ch = text.charAt(i);
    if (ch === '`') {
      const end = text.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        segs.push({ text: text.substring(i + 1, end), bold: false, code: true });
        i = end + 1;
        continue;
      }
    }
    buf += ch;
    i++;
  }
  flush();
  return segs;
}

function parseBlocks(text: string): MdBlock[] {
  const blocks: MdBlock[] = [];
  const lines = text.split('\n');
  let inCode: boolean = false;
  let codeLines: string[] = [];
  for (const rawLine of lines) {
    const line = rawLine;
    const trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      if (inCode) {
        blocks.push({ kind: 'code', text: codeLines.join('\n'), level: 0 });
        codeLines = [];
        inCode = false;
      } else {
        inCode = true;
      }
      continue;
    }
    if (inCode) { codeLines.push(line); continue; }

    const h = trimmed.match(/^(#{1,6})\s+(.*)$/);
    if (h) {
      blocks.push({ kind: 'heading', text: h[2], level: h[1].length });
      continue;
    }
    const ul = line.match(/^(\s*)[-*+]\s+(.*)$/);
    if (ul) {
      blocks.push({ kind: 'list', text: ul[2], level: 0 });
      continue;
    }
    const ol = line.match(/^(\s*)(\d+)\.\s+(.*)$/);
    if (ol) {
      blocks.push({ kind: 'list', text: ol[2] + '. ' + ol[3], level: 1 });
      continue;
    }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
      blocks.push({ kind: 'hr', text: '', level: 0 });
      continue;
    }
    if (trimmed.startsWith('>')) {
      blocks.push({ kind: 'quote', text: trimmed.replace(/^>\s?/, ''), level: 0 });
      continue;
    }
    if (trimmed.length === 0) { continue; }
    blocks.push({ kind: 'paragraph', text: line, level: 0 });
  }
  if (inCode && codeLines.length > 0) {
    blocks.push({ kind: 'code', text: codeLines.join('\n'), level: 0 });
  }
  return blocks;
}

@Component
struct MarkdownText {
  @Prop @Watch('onTextChanged') text: string = '';
  @Prop textColor: string = '#333333';
  @Prop fontSize: number = 15;
  @State segments: MdInline[] = [];

  aboutToAppear(): void { this.segments = parseInline(this.text); }
  onTextChanged(): void { this.segments = parseInline(this.text); }

  build() {
    Text() {
      ForEach(this.segments, (seg: MdInline, i: number) => {
        if (seg.code) {
          Span(seg.text)
            .fontFamily('monospace')
            .textBackgroundStyle({ color: '#F0F0F0', radius: 4 })
        } else if (seg.bold) {
          Span(seg.text).fontWeight(FontWeight.Bold)
        } else {
          Span(seg.text)
        }
      }, (seg: MdInline, i: number): string => 'seg_' + i)
    }
    .width('100%')
    .fontSize(this.fontSize)
    .fontColor(this.textColor)
    .lineHeight(22)
    .wordBreak(WordBreak.BREAK_ALL)
  }
}

/** 轻量 Markdown 渲染：标题、加粗、行内代码、代码块、列表、引用、分割线 */
@Component
export struct MarkdownView {
  @Prop @Watch('onTextChanged') text: string = '';
  @Prop textColor: string = '#333333';
  @Prop fontSize: number = 15;
  @State blocks: MdBlock[] = [];

  aboutToAppear(): void { this.blocks = parseBlocks(this.text); }
  onTextChanged(): void { this.blocks = parseBlocks(this.text); }

  build() {
    Column() {
      ForEach(this.blocks, (block: MdBlock, i: number) => {
        if (block.kind === 'heading') {
          Text(block.text)
            .width('100%')
            .fontSize(block.level <= 1 ? 20 : (block.level === 2 ? 18 : 16))
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor)
            .margin({ top: i === 0 ? 2 : 8, bottom: 4 })
        } else if (block.kind === 'code') {
          Scroll() {
            Text(block.text)
              .fontSize(12)
              .fontColor(this.textColor)
              .fontFamily('monospace')
              .lineHeight(18)
          }
          .scrollable(ScrollDirection.Horizontal)
          .width('100%').padding(10)
          .backgroundColor('#F5F5F5').borderRadius(8)
          .margin({ top: 4, bottom: 4 })
        } else if (block.kind === 'list') {
          Row() {
            if (block.level === 0) {
              Text('•').fontSize(this.fontSize).fontColor(this.textColor).margin({ right: 6 })
            }
            Column() {
              MarkdownText({ text: block.text, textColor: this.textColor, fontSize: this.fontSize })
            }.layoutWeight(1)
          }
          .width('100%').alignItems(VerticalAlign.Top).margin({ top: 2, bottom: 2 })
        } else if (block.kind === 'quote') {
          Row() {
            Divider().vertical(true).color('#D0D0D0').margin({ right: 8 })
            Column() {
              MarkdownText({ text: block.text, textColor: '#666666', fontSize: this.fontSize })
            }.layoutWeight(1)
          }
          .width('100%').alignItems(VerticalAlign.Top).margin({ top: 4, bottom: 4 })
        } else if (block.kind === 'hr') {
          Divider().width('100%').color('#E5E5E5').margin({ top: 8, bottom: 8 })
        } else {
          MarkdownText({ text: block.text, textColor: this.textColor, fontSize: this.fontSize })
        }
      }, (block: MdBlock, i: number): string => 'blk_' + i + '_' + block.kind)
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }
}
