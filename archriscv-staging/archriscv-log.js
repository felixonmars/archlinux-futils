'use strict';

// A log has scrollback, but no fixed terminal width: only explicit cursor moves
// replace text. Soft wrapping in the browser must not change cursor positions.
class TerminalLog {
  constructor(element = null) {
    this.element = element;
    this.lines = [{runs: [], length: 0}];
    this.nodes = [];
    this.dirty = new Set([0]);
    this.row = 0;
    this.column = 0;
    this.tail = '';
    this.attributes = {};
    this.style = '';
    this.link = '';
  }

  escape(text) {
    return text.replace(/[&<>"']/g, char => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[char]));
  }

  lineHTML(index) {
    return this.lines[index].runs.map(run => {
      let html = this.escape(run.text);
      if (run.style) html = `<span style="${run.style}">${html}</span>`;
      if (run.link) html = `<a href="${this.escape(run.link)}" rel="noreferrer">${html}</a>`;
      return html;
    }).join('');
  }

  toHTML() {
    return this.lines.map((_, index) => this.lineHTML(index)).join('\n');
  }

  flush() {
    if (this.element) {
      while (this.nodes.length < this.lines.length) {
        this.nodes.push(this.element.appendChild(document.createElement('span')));
      }
      for (const index of this.dirty) {
        this.nodes[index].innerHTML = this.lineHTML(index) + (index < this.lines.length - 1 ? '\n' : '');
      }
    }
    this.dirty.clear();
  }

  ensureRow() {
    while (this.lines.length <= this.row) {
      this.dirty.add(this.lines.length - 1);
      this.dirty.add(this.lines.length);
      this.lines.push({runs: [], length: 0});
    }
  }

  slice(runs, start, end = Infinity) {
    const result = [];
    let offset = 0;
    for (const run of runs) {
      const text = run.text.slice(Math.max(0, start - offset), Math.max(0, end - offset));
      if (text) result.push({...run, text});
      offset += run.text.length;
      if (offset >= end) break;
    }
    return result;
  }

  replace(start, end, text = '') {
    this.ensureRow();
    const line = this.lines[this.row];
    const runs = this.slice(line.runs, 0, start);
    if (text && start > line.length) runs.push({text: ' '.repeat(start - line.length), style: '', link: ''});
    if (text) runs.push({text, style: this.style, link: this.link});
    runs.push(...this.slice(line.runs, end));
    line.runs = [];
    line.length = 0;
    for (const run of runs) {
      const previous = line.runs[line.runs.length - 1];
      if (previous && previous.style === run.style && previous.link === run.link) previous.text += run.text;
      else line.runs.push({...run});
      line.length += run.text.length;
    }
    this.dirty.add(this.row);
  }

  color(index) {
    const colors = ['#667085', '#ff6b6b', '#9ece6a', '#f9c74f', '#7aa2f7', '#bb9af7', '#7dcfff', '#d8dee9',
      '#8992a3', '#ff8b8b', '#b9f27c', '#ffd166', '#9dbbff', '#d2a8ff', '#9be7ff', '#ffffff'];
    if (index < 16) return colors[index];
    if (index >= 232) return `rgb(${Array(3).fill(8 + (index - 232) * 10).join(',')})`;
    return `rgb(${[36, 6, 1].map(divisor => {
      const component = Math.floor((index - 16) / divisor) % 6;
      return component ? 55 + component * 40 : 0;
    }).join(',')})`;
  }

  sgr(params) {
    for (let index = 0; index < params.length; index++) {
      const code = params[index];
      if (code === 0) this.attributes = {};
      else if (code === 1) this.attributes['font-weight'] = '700';
      else if (code === 3) this.attributes['font-style'] = 'italic';
      else if (code === 4) this.attributes['text-decoration'] = 'underline';
      else if (code === 22) delete this.attributes['font-weight'];
      else if (code === 23) delete this.attributes['font-style'];
      else if (code === 24) delete this.attributes['text-decoration'];
      else if (code === 39) delete this.attributes.color;
      else if (code === 49) delete this.attributes['background-color'];
      else if (code >= 30 && code <= 37) this.attributes.color = this.color(code - 30);
      else if (code >= 90 && code <= 97) this.attributes.color = this.color(code - 90 + 8);
      else if (code >= 40 && code <= 47) this.attributes['background-color'] = this.color(code - 40);
      else if (code >= 100 && code <= 107) this.attributes['background-color'] = this.color(code - 100 + 8);
      else if (code === 38 || code === 48) {
        const property = code === 38 ? 'color' : 'background-color';
        const mode = params[++index];
        const count = mode === 2 ? 3 : mode === 5 ? 1 : 0;
        const values = params.slice(index + 1, index + 1 + count);
        if (count && values.length === count && values.every(value => value >= 0 && value <= 255)) {
          this.attributes[property] = mode === 2 ? `rgb(${values.join(',')})` : this.color(values[0]);
        }
        index += count;
      }
    }
    this.style = Object.entries(this.attributes).sort().map(([key, value]) => `${key}:${value}`).join(';');
  }

  csi(raw, final) {
    if (!/^[0-9;]*$/.test(raw)) return;
    const params = raw.split(';').map(value => Number(value));
    const count = params[0] || 1;
    if (final === 'm') this.sgr(params);
    else if (final === 'A') this.row = Math.max(0, this.row - count);
    else if (final === 'B') this.row += count;
    else if (final === 'C') this.column += count;
    else if (final === 'D') this.column = Math.max(0, this.column - count);
    else if (final === 'E') { this.row += count; this.column = 0; }
    else if (final === 'F') { this.row = Math.max(0, this.row - count); this.column = 0; }
    else if (final === 'G' || final === '`') this.column = count - 1;
    else if (final === 'K') {
      if (params[0] === 0) this.replace(this.column, Infinity);
      else if (params[0] === 1) this.replace(0, this.column + 1, ' '.repeat(this.column + 1));
      else if (params[0] === 2) this.replace(0, Infinity);
    }
  }

  write(chunk) {
    const text = this.tail + chunk;
    this.tail = '';
    const control = /[\x00-\x1f\x7f-\x9f]/g;
    let index = 0;
    while (index < text.length) {
      control.lastIndex = index;
      const match = control.exec(text);
      const start = match ? match.index : text.length;
      if (start > index) {
        const plain = text.slice(index, start);
        this.replace(this.column, this.column + plain.length, plain);
        this.column += plain.length;
      }
      if (!match) break;
      index = start + 1;
      const code = text[start];
      if (code === '\r') this.column = 0;
      else if (code === '\n') { this.row++; this.column = 0; this.ensureRow(); }
      else if (code === '\b') this.column = Math.max(0, this.column - 1);
      else if (code === '\t') this.column += 8 - this.column % 8;
      else if (code === '\x1b' || code === '\x9b' || code === '\x9d') {
        const next = text[index];
        if (code === '\x9b' || next === '[') {
          const paramsAt = code === '\x9b' ? index : index + 1;
          const sequence = /^([0-?]*[ -/]*)([@-~])/.exec(text.slice(paramsAt));
          if (!sequence) { this.tail = text.slice(start); break; }
          this.csi(sequence[1], sequence[2]);
          index = paramsAt + sequence[0].length;
        } else if (code === '\x9d' || next === ']' || ['P', '^', '_', 'X'].includes(next)) {
          const contentAt = code === '\x9d' ? index : index + 1;
          const end = /\x07|\x1b\\|\x9c/g;
          end.lastIndex = contentAt;
          const stop = end.exec(text);
          if (!stop) { this.tail = text.slice(start); break; }
          const content = text.slice(contentAt, stop.index);
          if ((code === '\x9d' || next === ']') && content.startsWith('8;')) {
            const url = content.slice(content.indexOf(';', 2) + 1);
            this.link = /^https?:\/\//i.test(url) ? url : '';
          }
          index = stop.index + stop[0].length;
        } else {
          const sequence = /^[ -/]*[0-~]/.exec(text.slice(index));
          if (!sequence) { this.tail = text.slice(start); break; }
          index += sequence[0].length;
        }
      }
    }
    this.flush();
  }
}
