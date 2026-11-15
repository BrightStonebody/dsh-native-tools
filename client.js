/**
 * DSH Native（客户端半边）：插件页里的配置面板。
 *
 * 三个功能（截图 / 剪贴板历史 / 翻译）共用一个原生进程，所以设置页是三个卡片，
 * 每张卡片顶部一个开关。开关写的是 `['<功能>','enabled']`，Host 收到
 * `loader/volatile-update` 后把该功能从进程里装上或卸下，其它两个不受影响。
 *
 * 这些字段在 index.js 里都声明了 `.volatile()`：改设置不会重启插件，Host 直接
 * 更新运行中的引用然后派发事件。也正因为如此，DSH 的 `volatileForm()` 才会把
 * 它们投影进设置命名空间——一个 volatile 字段都没有的插件，`form.state.status`
 * 永远是 'unavailable'，页面上就只剩一句「这个插件没有声明可配置项」。
 *
 * 注册到 `plugins.row.config`，key 是 plugin-manager 的行配置键
 * `rowConfigKey(bundle, rowId)` = `<包名>#<行 id>`。owner 传进来的 props 是
 * `{ view: 'summary' | 'page', form?: { state, mutate } }`：
 *   - `view === 'summary'`：插件列表行里的摘要，只画一行文字；
 *   - `view === 'page'`：插件详情页的主体，画完整表单。
 * Host 半边（index.js）声明了 Config，所以 `form.state` 里有
 * `{ status, value, revision, writable }`，写回用
 * `form.mutate([{ op: 'set', path: [...], value }], revision)`。
 */
window.__ModuleLoader__.load({
  id: 'dsh-native-tools',
  factory(require) {
    /** @type {any} */
    const React = require('react');
    const h = React.createElement;

    const PACKAGE = 'dsh-native-tools';
    const ROW_ID = 'dsh-native-tools';
    /** 与 dsh-client-ui-plugin-manager 的 rowConfigKey() 保持一致。 */
    const CONFIG_KEY = `${PACKAGE}#${ROW_ID}`;

    const FEATURES = [
      { slug: 'screenshot', label: '截图', defaultHotkey: 'cmd+shift+a', note: '拖框截屏：复制、另存、加红框、识别文字' },
      { slug: 'clipboard', label: '剪贴板历史', defaultHotkey: 'cmd+shift+v', note: '搜索、预览、回车粘贴历史记录' },
      { slug: 'translate', label: '翻译', defaultHotkey: 'cmd+shift+t', note: '选中文本或输入框里按快捷键出译文' },
      { slug: 'monitor', label: '系统监控', defaultHotkey: '', note: '状态栏三个图标：网络上下行、CPU、内存；点开看占用最高的进程' },
    ];

    /**
     * 翻译通道。前两个是匿名接口（不需要登录，浮窗这种「没有会话」的场合也能用）；
     * 后两个是 DSH 自己的付费通道，要求一个活的 Session 才能记账，
     * 而全局快捷键弹出来的浮窗根本没有会话，所以只列出来说明原因、不允许选。
     * 取值必须与 @deepseek-ai/dsh-experimental-translator 的 Config 联合类型一致，
     * 否则它连挂载都过不了（Config 校验失败）。
     */
    const PROVIDERS = [
      { value: 'bing', label: 'bing（默认，无需登录）' },
      { value: 'google', label: 'google（无需登录，需要能直接访问 Google）' },
      { value: 'deepseek-account', label: 'deepseek-account（要 DeepSeek 账号，只能在对话里用）', disabled: true },
      { value: 'deepseek-official', label: 'deepseek-official（要 API Key，只能在对话里用）', disabled: true },
    ];

    const CSS = `
      .dsh-ss{display:flex;flex-direction:column;gap:16px;color:var(--dsw-alias-label-primary,#111);font-size:13px;line-height:20px}
      .dsh-ss *{box-sizing:border-box}
      .dsh-ss-card{display:flex;flex-direction:column;gap:12px;padding:14px 16px;border-radius:12px;border:0.5px solid var(--dsw-alias-border-l2,#00000029);background:var(--dsw-alias-bg-layer-1,#fff)}
      .dsh-ss-card--off{opacity:.62}
      .dsh-ss-head{display:flex;align-items:center;justify-content:space-between;gap:12px}
      .dsh-ss-title{font-weight:600;font-size:13px;line-height:18px}
      .dsh-ss-note{color:var(--dsw-alias-label-tertiary,#888);font-size:11px;line-height:16px}
      .dsh-ss-field{display:flex;flex-direction:column;gap:6px}
      .dsh-ss-label{font-weight:600;font-size:12px;line-height:18px}
      .dsh-ss-hint{color:var(--dsw-alias-label-tertiary,#888);font-size:11px;line-height:16px}
      .dsh-ss-row{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
      .dsh-ss-input{flex:1 1 200px;min-width:150px;font:inherit;font-size:13px;line-height:22px;padding:5px 10px;border-radius:8px;border:0.5px solid var(--dsw-alias-border-l2,#00000029);background:var(--dsw-alias-bg-layer-1,#fff);color:var(--dsw-alias-label-primary,#111);outline:none}
      .dsh-ss-input:focus{border-color:var(--dsw-alias-state-business-primary,#4c8dff);box-shadow:0 0 0 3px color-mix(in srgb,var(--dsw-alias-state-business-primary,#4c8dff) 18%,transparent)}
      .dsh-ss-input[data-recording]{border-color:var(--dsw-alias-state-business-primary,#4c8dff);background:color-mix(in srgb,var(--dsw-alias-state-business-primary,#4c8dff) 8%,var(--dsw-alias-bg-layer-1,#fff))}
      .dsh-ss-input--narrow{flex:0 0 92px;min-width:92px}
      .dsh-ss-select{appearance:auto;padding-right:6px;cursor:pointer}
      .dsh-ss-select[disabled]{cursor:default}
      .dsh-ss-btn{font:inherit;font-size:12px;line-height:20px;padding:4px 12px;border-radius:8px;border:0.5px solid var(--dsw-alias-border-l2,#00000029);background:var(--dsw-alias-bg-layer-1,#f6f6f6);color:var(--dsw-alias-label-primary,#111);cursor:pointer;white-space:nowrap}
      .dsh-ss-btn:hover:not([disabled]){background:var(--dsw-alias-interactive-bg-hover,#0000000f)}
      .dsh-ss-btn[disabled]{opacity:.5;cursor:default}
      .dsh-ss-btn--primary{background:var(--dsw-alias-state-business-primary,#4c8dff);border-color:transparent;color:#fff}
      .dsh-ss-btn--primary:hover:not([disabled]){background:var(--dsw-alias-button-primary-hover,#3d7ce8)}
      .dsh-ss-switch{position:relative;flex:0 0 auto;width:36px;height:20px;padding:0;border:0;border-radius:999px;background:var(--dsw-alias-fill-tertiary,rgba(0,0,0,.18));cursor:pointer;transition:background .15s ease}
      .dsh-ss-switch[disabled]{opacity:.5;cursor:default}
      .dsh-ss-switch--on{background:var(--dsw-alias-state-business-primary,#4c8dff)}
      .dsh-ss-knob{position:absolute;top:2px;left:2px;width:16px;height:16px;border-radius:999px;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.25);transition:transform .15s ease}
      .dsh-ss-switch--on .dsh-ss-knob{transform:translateX(16px)}
      .dsh-ss-chips{display:flex;gap:6px;flex-wrap:wrap}
      .dsh-ss-chip{font:inherit;font-size:12px;line-height:18px;padding:3px 9px;border-radius:999px;border:0.5px solid var(--dsw-alias-border-l2,#00000029);background:transparent;color:var(--dsw-alias-label-secondary,#555);cursor:pointer}
      .dsh-ss-chip:hover:not([disabled]){background:var(--dsw-alias-interactive-bg-hover,#0000000f)}
      .dsh-ss-chip[disabled]{opacity:.5;cursor:default}
      .dsh-ss-chip--on{background:var(--dsw-alias-state-business-primary,#4c8dff);border-color:transparent;color:#fff}
      .dsh-ss-check{display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--dsw-alias-label-secondary,#555)}
      .dsh-ss-check input{accent-color:var(--dsw-alias-state-business-primary,#4c8dff)}
      .dsh-ss-combo{font-size:20px;line-height:28px;font-weight:600;letter-spacing:.02em;min-height:28px}
      .dsh-ss-err{color:var(--dsw-alias-state-error-primary,#e5484d);font-size:11px;line-height:16px}
      .dsh-ss-ok{color:var(--dsw-alias-state-success-primary,#2bb673);font-size:11px;line-height:16px}
      .dsh-ss-summary{color:var(--dsw-alias-label-secondary,#555);font-size:12px;line-height:18px}
    `;

    function mountStyles() {
      const id = `${PACKAGE}/settings.css`;
      if (document.querySelector(`style[data-plugin-css="${id}"]`) !== null) return () => {};
      const tag = document.createElement('style');
      tag.dataset.plugin = PACKAGE;
      tag.dataset.pluginCss = id;
      tag.textContent = CSS;
      document.head.appendChild(tag);
      return () => tag.remove();
    }

    // ---- 快捷键文法：与 engine/Sources/NativeKit/Core/HotKey.swift 的
    // ---- KeySpecParser 对齐。前端先校验，helper 端再校验一次；两边不一致时
    // ---- 以 helper 的 HUD 报错为准。

    const MODIFIERS = {
      cmd: ['cmd', '⌘'],
      command: ['cmd', '⌘'],
      '⌘': ['cmd', '⌘'],
      shift: ['shift', '⇧'],
      '⇧': ['shift', '⇧'],
      opt: ['opt', '⌥'],
      option: ['opt', '⌥'],
      alt: ['opt', '⌥'],
      '⌥': ['opt', '⌥'],
      ctrl: ['ctrl', '⌃'],
      control: ['ctrl', '⌃'],
      '⌃': ['ctrl', '⌃'],
    };
    /** 规范名 → 显示字形；字母数字键直接用大写。 */
    const KEY_GLYPHS = {
      space: 'Space',
      return: '↩',
      enter: '↩',
      tab: '⇥',
      escape: '⎋',
      esc: '⎋',
      delete: '⌫',
      backspace: '⌫',
      forwarddelete: '⌦',
      del: '⌦',
      home: '↖',
      end: '↘',
      pageup: '⇞',
      pagedown: '⇟',
      insert: '⎀',
      help: '⎀',
      left: '←',
      right: '→',
      up: '↑',
      down: '↓',
      leftarrow: '←',
      rightarrow: '→',
      uparrow: '↑',
      downarrow: '↓',
      minus: '-',
      equal: '=',
      equals: '=',
      leftbracket: '[',
      rightbracket: ']',
      semicolon: ';',
      quote: "'",
      comma: ',',
      period: '.',
      slash: '/',
      backslash: '\\',
      grave: '`',
    };
    const NAMED_KEYS = new Set(Object.keys(KEY_GLYPHS));
    /** 别名 → 规范名：两者都能写进配置，但落盘统一用规范名。 */
    const KEY_ALIASES = {
      enter: 'return',
      esc: 'escape',
      backspace: 'delete',
      del: 'forwarddelete',
      equals: 'equal',
      leftarrow: 'left',
      rightarrow: 'right',
      uparrow: 'up',
      downarrow: 'down',
    };
    /** 只有功能键允许不带修饰符，否则单字母热键会吞掉全局输入。 */
    const FUNCTION_KEY = /^f([1-9]|1[0-9]|20)$/;

    /** 单个标点字符 → 键名，`cmd+shift+-`、`cmd+,` 这类写法都落在这里。 */
    const PUNCTUATION = {
      '-': 'minus', '=': 'equal', '[': 'leftbracket', ']': 'rightbracket',
      ';': 'semicolon', "'": 'quote', ',': 'comma', '.': 'period',
      '/': 'slash', '\\': 'backslash', '`': 'grave',
    };

    function canonicalKey(token) {
      const raw = token.trim().toLowerCase();
      if (raw === '') return null;
      if (raw.length === 1 && /[a-z0-9]/.test(raw)) return raw;
      if (PUNCTUATION[raw] !== undefined) return PUNCTUATION[raw];
      if (FUNCTION_KEY.test(raw)) return raw;
      const name = KEY_ALIASES[raw] ?? raw;
      if (NAMED_KEYS.has(name) || NAMED_KEYS.has(raw)) {
        return KEY_ALIASES[name] ?? name;
      }
      return null;
    }

    function keyGlyph(token) {
      if (KEY_GLYPHS[token] !== undefined) return KEY_GLYPHS[token];
      if (FUNCTION_KEY.test(token)) return token.toUpperCase();
      return token.toUpperCase();
    }

    /**
     * 解析用户写法，返回 { canonical, label } 或 { error }。
     * 支持 `cmd+shift+a`、`⌃⌥K`、`f8`，分隔符可以是 `+`、空格，或（仅当整串
     * 不含 `+` 时）`-`——这样 `cmd-shift--` 这种写法仍能落到 minus 上。
     */
    function parseHotkey(input) {
      const text = String(input ?? '').trim();
      if (text === '') return { error: '快捷键不能为空' };
      let tokens = text.split(/[+\s]+/).filter((token) => token !== '');
      // 「⌃⌥K」「⇧⌘3」这类写法整串没有分隔符：把前缀的修饰键字形剥出来。
      if (tokens.length === 1) {
        let rest = tokens[0];
        const peeled = [];
        for (let guard = 0; guard < 4; guard += 1) {
          const head = rest.slice(0, 1);
          if (head === '' || MODIFIERS[head] === undefined) break;
          peeled.push(head);
          rest = rest.slice(1);
        }
        if (peeled.length > 0 && rest !== '') tokens = [...peeled, rest];
      }
      if (tokens.length === 1 && tokens[0].includes('-')) {
        const parts = tokens[0].split('-').filter((token) => token !== '');
        // `cmd-shift--`：末尾的 `-` 是键本身。
        if (tokens[0].endsWith('--')) parts.push('-');
        const rebuilt = parts.map((token) => (token === '-' ? 'minus' : token));
        if (rebuilt.every((token) => MODIFIERS[token.toLowerCase()] !== undefined || canonicalKey(token) !== null)) {
          tokens = rebuilt;
        }
      }
      const mods = { cmd: false, shift: false, opt: false, ctrl: false };
      let key = null;
      for (const token of tokens) {
        const modifier = MODIFIERS[token.toLowerCase()];
        if (modifier !== undefined) {
          mods[modifier[0]] = true;
          continue;
        }
        const candidate = canonicalKey(token);
        if (candidate === null) return { error: `无法识别「${token}」` };
        if (key !== null) return { error: '一个快捷键只能有一个主键' };
        key = candidate;
      }
      if (key === null) return { error: '缺少主键（例如 2、a、f8）' };
      const hasModifier = mods.cmd || mods.shift || mods.opt || mods.ctrl;
      if (!hasModifier && !FUNCTION_KEY.test(key)) {
        return { error: '必须带至少一个修饰键（⌘ ⌥ ⌃ ⇧），或使用 F1–F20' };
      }
      const parts = [];
      const glyphs = [];
      if (mods.ctrl) { parts.push('ctrl'); }
      if (mods.opt) { parts.push('opt'); }
      if (mods.shift) { parts.push('shift'); }
      if (mods.cmd) { parts.push('cmd'); }
      // 字形顺序固定 ⌃⌥⇧⌘，与 helper 的 KeySpecParser.label 一致。
      if (mods.ctrl) glyphs.push('⌃');
      if (mods.opt) glyphs.push('⌥');
      if (mods.shift) glyphs.push('⇧');
      if (mods.cmd) glyphs.push('⌘');
      parts.push(key);
      glyphs.push(keyGlyph(key));
      return { canonical: parts.join('+'), label: glyphs.join('') };
    }

    /** 浏览器按键事件 → 配置写法。只接受能无损映射的组合。 */
    function fromKeyEvent(event) {
      const code = event.code ?? '';
      let key = null;
      if (/^Key[A-Z]$/.test(code)) key = code.slice(3).toLowerCase();
      else if (/^Digit[0-9]$/.test(code)) key = code.slice(5);
      else if (/^F([1-9]|1[0-9]|20)$/.test(code)) key = code.toLowerCase();
      else {
        const byCode = {
          Minus: 'minus', Equal: 'equal', BracketLeft: 'leftbracket', BracketRight: 'rightbracket',
          Backslash: 'backslash', Semicolon: 'semicolon', Quote: 'quote', Comma: 'comma',
          Period: 'period', Slash: 'slash', Backquote: 'grave', Space: 'space',
          Enter: 'return', NumpadEnter: 'return', Tab: 'tab', Escape: 'escape',
          Backspace: 'delete', Delete: 'forwarddelete', Home: 'home', End: 'end',
          PageUp: 'pageup', PageDown: 'pagedown', ArrowLeft: 'left', ArrowRight: 'right',
          ArrowUp: 'up', ArrowDown: 'down',
        };
        key = byCode[code] ?? null;
      }
      if (key === null) return null;
      const parts = [];
      if (event.ctrlKey) parts.push('ctrl');
      if (event.altKey) parts.push('opt');
      if (event.shiftKey) parts.push('shift');
      if (event.metaKey) parts.push('cmd');
      parts.push(key);
      return parts.join('+');
    }

    const PRESETS = ['cmd+shift+a', 'cmd+shift+v', 'cmd+shift+t', 'ctrl+opt+a', 'f8'];

    // ---- 读配置 ---------------------------------------------------------

    function groupOf(value, slug) {
      const group = value === null || typeof value !== 'object' ? undefined : value[slug];
      return group !== null && typeof group === 'object' ? group : {};
    }

    function hotkeyOf(group, fallback) {
      return typeof group.hotkey === 'string' && group.hotkey.trim() !== '' ? group.hotkey.trim() : fallback;
    }

    /**
     * 下拉框的选项。当前值如果不在名单里（比如配置文件被人手改成了别的名字），
     * 也要把它列出来，否则 select 会显示成第一项，看起来像「自己变回 bing 了」。
     */
    function providerOptions(current) {
      const known = PROVIDERS.some((provider) => provider.value === current);
      const options = PROVIDERS.map((provider) =>
        h('option', { key: provider.value, value: provider.value, disabled: provider.disabled === true }, provider.label),
      );
      if (!known && typeof current === 'string' && current !== '') {
        options.push(h('option', { key: current, value: current }, `${current}（不在可选之列，翻译会失败）`));
      }
      return options;
    }

    /** 从 form 快照里取当前值；配置还没读到时先用包内默认值。 */
    function valuesOf(form) {
      const value = form?.state?.value ?? {};
      const screenshot = groupOf(value, 'screenshot');
      const clipboard = groupOf(value, 'clipboard');
      const translate = groupOf(value, 'translate');
      const monitor = groupOf(value, 'monitor');
      return {
        screenshot: {
          enabled: screenshot.enabled !== false,
          hotkey: hotkeyOf(screenshot, FEATURES[0].defaultHotkey),
          saveDirectory: typeof screenshot.saveDirectory === 'string' ? screenshot.saveDirectory : '',
          ocrLanguages: typeof screenshot.ocrLanguages === 'string' && screenshot.ocrLanguages.trim() !== ''
            ? screenshot.ocrLanguages.trim()
            : 'auto',
          keepLineBreaks: screenshot.ocrKeepLineBreaks !== false,
        },
        clipboard: {
          enabled: clipboard.enabled !== false,
          hotkey: hotkeyOf(clipboard, FEATURES[1].defaultHotkey),
          maxItems: Number.isFinite(clipboard.maxItems) ? clipboard.maxItems : 200,
          retentionDays: Number.isFinite(clipboard.retentionDays) ? clipboard.retentionDays : 30,
        },
        translate: {
          enabled: translate.enabled !== false,
          hotkey: hotkeyOf(translate, FEATURES[2].defaultHotkey),
          provider: typeof translate.provider === 'string' && translate.provider.trim() !== '' ? translate.provider.trim() : 'bing',
          targetLanguage: typeof translate.targetLanguage === 'string' && translate.targetLanguage.trim() !== ''
            ? translate.targetLanguage.trim()
            : 'auto',
        },
        monitor: {
          enabled: monitor.enabled !== false,
          refreshSeconds: Number.isFinite(monitor.refreshSeconds) ? monitor.refreshSeconds : 2,
          topCount: Number.isFinite(monitor.topCount) ? monitor.topCount : 8,
          showNetwork: monitor.showNetwork !== false,
          showCPU: monitor.showCPU !== false,
          showMemory: monitor.showMemory !== false,
          networkDetailed: monitor.networkDetailed !== false,
        },
      };
    }

    /** 摘要行：插件列表里显示三个功能各自的状态。 */
    function SummaryRow(props) {
      try {
        const values = valuesOf(props.form);
        const parts = FEATURES.map((feature) => {
          const group = values[feature.slug];
          if (!group.enabled) return `${feature.label} 关`;
          // 系统监控没有快捷键，摘要里只报开关。
          if (!feature.defaultHotkey) return `${feature.label} 开`;
          const parsed = parseHotkey(group.hotkey);
          return `${feature.label} ${parsed.label ?? group.hotkey}`;
        });
        return h('div', { className: 'dsh-ss-summary', 'data-dsh-native-tools-summary': '' }, parts.join(' · '));
      } catch (error) {
        return h('div', { className: 'dsh-ss-err' }, String(error && error.message ? error.message : error));
      }
    }

    function Switch(props) {
      // 内联样式是兜底：样式表若因为任何原因没挂上，开关也仍然是看得见的 36×20 胶囊。
      return h('button', {
        type: 'button',
        role: 'switch',
        'aria-checked': props.on ? 'true' : 'false',
        'aria-label': props.label,
        className: props.on ? 'dsh-ss-switch dsh-ss-switch--on' : 'dsh-ss-switch',
        disabled: props.disabled,
        style: {
          position: 'relative',
          flex: '0 0 auto',
          display: 'inline-block',
          width: 36,
          height: 20,
          padding: 0,
          border: 0,
          borderRadius: 999,
          background: props.on ? 'var(--dsw-alias-state-business-primary, #4c8dff)' : 'var(--dsw-alias-fill-tertiary, rgba(0,0,0,.18))',
          cursor: props.disabled ? 'default' : 'pointer',
          opacity: props.disabled ? 0.5 : 1,
        },
        onClick: () => props.onChange(!props.on),
      }, h('span', {
        className: 'dsh-ss-knob',
        style: {
          position: 'absolute',
          top: 2,
          left: 2,
          width: 16,
          height: 16,
          borderRadius: 999,
          background: '#fff',
          transform: props.on ? 'translateX(16px)' : 'translateX(0)',
          transition: 'transform .15s ease',
        },
      }));
    }

    // ---- 完整设置页 -----------------------------------------------------

    class SettingsPage extends React.Component {
      constructor(props) {
        super(props);
        const values = valuesOf(props.form);
        this.state = {
          draft: {
            screenshot: values.screenshot.hotkey,
            clipboard: values.clipboard.hotkey,
            translate: values.translate.hotkey,
          },
          fields: {
            saveDirectory: values.screenshot.saveDirectory,
            ocrLanguages: values.screenshot.ocrLanguages,
            keepLineBreaks: values.screenshot.keepLineBreaks,
            maxItems: String(values.clipboard.maxItems),
            retentionDays: String(values.clipboard.retentionDays),
            provider: values.translate.provider,
            targetLanguage: values.translate.targetLanguage,
            refreshSeconds: String(values.monitor.refreshSeconds),
            topCount: String(values.monitor.topCount),
            showNetwork: values.monitor.showNetwork,
            showCPU: values.monitor.showCPU,
            showMemory: values.monitor.showMemory,
            networkDetailed: values.monitor.networkDetailed,
          },
          recording: '',
          error: '',
          saved: '',
          busy: false,
        };
        this.onKeyDown = this.onKeyDown.bind(this);
      }

      componentDidUpdate() {
        if (this.state.busy || this.state.recording !== '') return;
        const values = valuesOf(this.props.form);
        const next = {};
        for (const feature of FEATURES) {
          if (!feature.defaultHotkey) continue;
          const current = values[feature.slug].hotkey;
          const draft = this.state.draft[feature.slug];
          // 只在草稿本身就是无效写法时才接受外部更新，否则会打断用户输入。
          if (current !== draft && parseHotkey(draft).error !== undefined) next[feature.slug] = current;
        }
        if (Object.keys(next).length > 0) {
          this.setState({ draft: { ...this.state.draft, ...next } });
        }
      }

      async write(path, value, okText) {
        const form = this.props.form;
        if (form === undefined || form === null) {
          this.setState({ error: '配置还没准备好（form 不可用）' });
          return false;
        }
        this.setState({ busy: true, error: '', saved: '' });
        try {
          await form.mutate([{ op: 'set', path, value }], form.state?.revision);
          this.setState({ busy: false, saved: okText ?? '已保存，正在应用…' });
          return true;
        } catch (error) {
          const message = error && error.message ? error.message : String(error);
          this.setState({ busy: false, error: `保存失败：${message}` });
          return false;
        }
      }

      async toggleFeature(slug, next) {
        await this.write([slug, 'enabled'], next, next ? '已打开，正在装载…' : '已关闭，正在卸下…');
      }

      async applyHotkey(slug, text) {
        const parsed = parseHotkey(text);
        if (parsed.error !== undefined) {
          this.setState({ error: parsed.error, saved: '' });
          return;
        }
        this.setState({ draft: { ...this.state.draft, [slug]: parsed.canonical } });
        await this.write([slug, 'hotkey'], parsed.canonical);
      }

      onKeyDown(event) {
        const slug = this.state.recording;
        if (slug === '') return;
        event.preventDefault();
        event.stopPropagation();
        if (event.key === 'Escape') {
          this.setState({ recording: '', error: '' });
          return;
        }
        const combo = fromKeyEvent(event);
        if (combo === null) {
          this.setState({ error: '这个键暂不支持，试试字母、数字、F1–F20 或方向键' });
          return;
        }
        const parsed = parseHotkey(combo);
        if (parsed.error !== undefined) {
          this.setState({ error: parsed.error });
          return;
        }
        this.setState({ recording: '', draft: { ...this.state.draft, [slug]: parsed.canonical } });
        void this.applyHotkey(slug, parsed.canonical);
      }

      hotkeyField(feature, enabled, writable) {
        const draft = this.state.draft[feature.slug];
        const parsed = parseHotkey(draft);
        const preview = parsed.label ?? draft;
        const recording = this.state.recording === feature.slug;
        return h('div', { className: 'dsh-ss-field', key: `${feature.slug}-hotkey` },
          h('div', { className: 'dsh-ss-label' }, `${feature.label}快捷键`),
          h('div', { className: 'dsh-ss-combo', 'data-hotkey-preview': feature.slug }, preview),
          h('div', { className: 'dsh-ss-row' },
            h('input', {
              className: 'dsh-ss-input',
              value: draft,
              spellCheck: false,
              autoComplete: 'off',
              placeholder: feature.defaultHotkey,
              disabled: !writable || !enabled || this.state.busy,
              'data-hotkey-input': feature.slug,
              'data-recording': recording ? '' : undefined,
              onChange: (event) => {
                this.setState({ draft: { ...this.state.draft, [feature.slug]: event.target.value }, error: '', saved: '' });
              },
              onKeyDown: this.onKeyDown,
              onBlur: () => { if (recording) this.setState({ recording: '' }); },
            }),
            h('button', {
              className: recording ? 'dsh-ss-btn dsh-ss-btn--primary' : 'dsh-ss-btn',
              disabled: !writable || !enabled || this.state.busy,
              onClick: (event) => {
                const next = recording ? '' : feature.slug;
                this.setState({ recording: next, error: '', saved: '' });
                event.currentTarget.blur();
                const input = event.currentTarget.parentElement?.querySelector(`input[data-hotkey-input="${feature.slug}"]`);
                if (input !== null && input !== undefined) input.focus();
              },
            }, recording ? '按下组合键…' : '录制'),
            h('button', {
              className: 'dsh-ss-btn dsh-ss-btn--primary',
              disabled: !writable || !enabled || this.state.busy || parsed.error !== undefined,
              onClick: () => void this.applyHotkey(feature.slug, draft),
            }, '应用'),
          ),
          parsed.error !== undefined
            ? h('div', { className: 'dsh-ss-err', 'data-hotkey-error': feature.slug }, parsed.error)
            : h('div', { className: 'dsh-ss-hint' }, '写法示例：cmd+shift+a · ctrl+opt+k · f8。点「录制」直接按下组合键。'),
          h('div', { className: 'dsh-ss-chips' }, PRESETS.map((preset) => h('button', {
            key: preset,
            className: 'dsh-ss-chip',
            disabled: !writable || !enabled || this.state.busy,
            onClick: () => void this.applyHotkey(feature.slug, preset),
          }, parseHotkey(preset).label ?? preset))),
        );
      }

      renderScreenshot(enabled, writable) {
        const fields = this.state.fields;
        const busy = this.state.busy || !writable || !enabled;
        return [
          this.hotkeyField(FEATURES[0], enabled, writable),
          h('div', { className: 'dsh-ss-field', key: 'save-directory' },
            h('div', { className: 'dsh-ss-label' }, '「保存」默认目录'),
            h('div', { className: 'dsh-ss-row' },
              h('input', {
                className: 'dsh-ss-input',
                value: fields.saveDirectory,
                spellCheck: false,
                placeholder: '留空 = 桌面',
                disabled: busy,
                onChange: (event) => {
                  this.setState({ fields: { ...fields, saveDirectory: event.target.value }, error: '', saved: '' });
                },
              }),
              h('button', {
                className: 'dsh-ss-btn',
                disabled: busy,
                onClick: () => void this.write(['screenshot', 'saveDirectory'], fields.saveDirectory.trim()),
              }, '保存'),
            ),
            h('div', { className: 'dsh-ss-hint' }, '写绝对路径，例如 /Users/you/Pictures/Shots；留空则保存到桌面。'),
          ),
          h('div', { className: 'dsh-ss-field', key: 'ocr' },
            h('div', { className: 'dsh-ss-label' }, '文字识别'),
            h('div', { className: 'dsh-ss-chips', 'data-ocr-languages': '' }, [
              ['auto', '自动判断'],
              ['zh', '中文优先'],
              ['en', '英文优先'],
            ].map(([value, label]) => h('button', {
              key: value,
              className: fields.ocrLanguages === value ? 'dsh-ss-chip dsh-ss-chip--on' : 'dsh-ss-chip',
              disabled: busy,
              onClick: () => {
                this.setState({ fields: { ...fields, ocrLanguages: value } });
                void this.write(['screenshot', 'ocrLanguages'], value);
              },
            }, label))),
            h('label', { className: 'dsh-ss-check' },
              h('input', {
                type: 'checkbox',
                checked: fields.keepLineBreaks,
                disabled: busy,
                onChange: (event) => {
                  const next = event.target.checked;
                  this.setState({ fields: { ...fields, keepLineBreaks: next } });
                  void this.write(['screenshot', 'ocrKeepLineBreaks'], next);
                },
              }),
              h('span', null, '保留屏幕上的换行'),
            ),
            h('div', { className: 'dsh-ss-hint' },
              '工具条的「文」或 ⌘T 识别当前选区，⌥⏎ 直接复制文字；确认截图时剪贴板同时带图片和文字。'),
          ),
        ];
      }

      renderClipboard(enabled, writable) {
        const fields = this.state.fields;
        const busy = this.state.busy || !writable || !enabled;
        const numberField = (key, label, hint) => h('div', { className: 'dsh-ss-field', key },
          h('div', { className: 'dsh-ss-label' }, label),
          h('div', { className: 'dsh-ss-row' },
            h('input', {
              className: 'dsh-ss-input dsh-ss-input--narrow',
              value: fields[key],
              inputMode: 'numeric',
              disabled: busy,
              onChange: (event) => {
                this.setState({ fields: { ...fields, [key]: event.target.value.replace(/[^0-9]/g, '') }, error: '', saved: '' });
              },
            }),
            h('button', {
              className: 'dsh-ss-btn',
              disabled: busy,
              onClick: () => {
                const parsed = Number.parseInt(fields[key], 10);
                if (!Number.isFinite(parsed) || parsed <= 0) {
                  this.setState({ error: `${label}要填正整数` });
                  return;
                }
                void this.write(['clipboard', key], parsed);
              },
            }, '保存'),
          ),
          h('div', { className: 'dsh-ss-hint' }, hint),
        );
        return [
          this.hotkeyField(FEATURES[1], enabled, writable),
          numberField('maxItems', '最多保留条数', '超过这个数量的旧记录会被清掉，默认 200。'),
          numberField('retentionDays', '保留天数', '超过天数的记录自动清理，默认 30 天。'),
        ];
      }

      renderTranslate(enabled, writable) {
        const fields = this.state.fields;
        const busy = this.state.busy || !writable || !enabled;
        return [
          this.hotkeyField(FEATURES[2], enabled, writable),
          h('div', { className: 'dsh-ss-field', key: 'provider' },
            h('div', { className: 'dsh-ss-label' }, '翻译通道'),
            h('div', { className: 'dsh-ss-row' },
              h('select', {
                className: 'dsh-ss-input dsh-ss-select',
                value: fields.provider,
                disabled: busy,
                onChange: (event) => {
                  const next = event.target.value;
                  this.setState({ fields: { ...fields, provider: next }, error: '', saved: '' });
                  void this.write(['translate', 'provider'], next, '已切换翻译通道');
                },
              }, providerOptions(fields.provider)),
            ),
            h('div', { className: 'dsh-ss-hint' }, 'bing / google 不需要登录；两个 deepseek 通道要账号，且必须在对话里用，浮窗调不到。'),
          ),
          h('div', { className: 'dsh-ss-field', key: 'target' },
            h('div', { className: 'dsh-ss-label' }, '目标语言'),
            h('div', { className: 'dsh-ss-row' },
              h('input', {
                className: 'dsh-ss-input',
                value: fields.targetLanguage,
                spellCheck: false,
                placeholder: 'auto',
                disabled: busy,
                onChange: (event) => {
                  this.setState({ fields: { ...fields, targetLanguage: event.target.value }, error: '', saved: '' });
                },
              }),
              h('button', {
                className: 'dsh-ss-btn',
                disabled: busy,
                onClick: () => void this.write(['translate', 'targetLanguage'], fields.targetLanguage.trim()),
              }, '保存'),
            ),
            h('div', { className: 'dsh-ss-hint' }, 'auto：中文进英文出、其他进中文；也可写 zh / en / ja。'),
          ),
        ];
      }

      renderMonitor(enabled, writable) {
        const fields = this.state.fields;
        const busy = this.state.busy || !writable || !enabled;

        const metricSwitch = (key, label, hint) => h('div', { className: 'dsh-ss-field', key },
          h('div', { className: 'dsh-ss-head' },
            h('div', null,
              h('div', { className: 'dsh-ss-label' }, label),
              h('div', { className: 'dsh-ss-hint' }, hint),
            ),
            h(Switch, {
              on: fields[key] !== false,
              label,
              disabled: busy,
              onChange: (next) => {
                this.setState({ fields: { ...fields, [key]: next }, error: '', saved: '' });
                void this.write(['monitor', key], next, next ? '图标已显示' : '图标已隐藏');
              },
            }),
          ),
        );

        const numberField = (key, label, hint) => h('div', { className: 'dsh-ss-field', key },
          h('div', { className: 'dsh-ss-label' }, label),
          h('div', { className: 'dsh-ss-row' },
            h('input', {
              className: 'dsh-ss-input dsh-ss-input--narrow',
              value: fields[key],
              inputMode: 'numeric',
              disabled: busy,
              onChange: (event) => {
                this.setState({ fields: { ...fields, [key]: event.target.value.replace(/[^0-9]/g, '') }, error: '', saved: '' });
              },
            }),
            h('button', {
              className: 'dsh-ss-btn',
              disabled: busy,
              onClick: () => {
                const parsed = Number.parseInt(fields[key], 10);
                if (!Number.isFinite(parsed) || parsed <= 0) {
                  this.setState({ error: `${label}要填正整数` });
                  return;
                }
                void this.write(['monitor', key], parsed);
              },
            }, '保存'),
          ),
          h('div', { className: 'dsh-ss-hint' }, hint),
        );

        return [
          metricSwitch('showNetwork', '网络图标', '显示 ↓下行 ↑上行 的实时速率'),
          metricSwitch('showCPU', 'CPU 图标', '显示整机 CPU 占用百分比'),
          metricSwitch('showMemory', '内存图标', '显示已用内存百分比'),
          numberField('refreshSeconds', '采样间隔（秒）', '菜单栏数字多久刷一次，默认 2 秒，允许 1–60。'),
          numberField('topCount', '排名条数', '点开图标后列出多少个进程，默认 8，允许 3–30。'),
          h('div', { className: 'dsh-ss-field', key: 'networkDetailed' },
            h('label', { className: 'dsh-ss-check' },
              h('input', {
                type: 'checkbox',
                checked: fields.networkDetailed !== false,
                disabled: busy,
                onChange: (event) => {
                  const next = event.target.checked;
                  this.setState({ fields: { ...fields, networkDetailed: next }, error: '', saved: '' });
                  void this.write(['monitor', 'networkDetailed'], next);
                },
              }),
              h('span', null, '网络图标同时显示上行'),
            ),
            h('div', { className: 'dsh-ss-hint' },
              '关掉后只显示 ↓ 下行速率，图标更窄；三个图标的数字都在采样间隔后更新一次。'),
          ),
        ];
      }

      renderCard(feature, enabled, writable, body) {
        return h('section', {
          key: feature.slug,
          className: enabled ? 'dsh-ss-card' : 'dsh-ss-card dsh-ss-card--off',
          'data-feature': feature.slug,
        },
          h('div', { className: 'dsh-ss-head' },
            h('div', null,
              h('div', { className: 'dsh-ss-title' }, feature.label),
              h('div', { className: 'dsh-ss-note' }, feature.note),
            ),
            h(Switch, {
              on: enabled,
              label: `启用${feature.label}`,
              disabled: !writable || this.state.busy,
              onChange: (next) => void this.toggleFeature(feature.slug, next),
            }),
          ),
          enabled ? body : h('div', { className: 'dsh-ss-hint' }, '这个功能关着，打开后才会注册快捷键、占用面板或占用菜单栏。'),
        );
      }

      render() {
        const { form } = this.props;
        const status = form?.state?.status ?? 'unavailable';
        const writable = form?.state?.writable !== false;

        if (status === 'loading') {
          return h('div', { className: 'dsh-ss' }, '正在读取配置…');
        }
        if (status === 'unavailable') {
          return h('div', { className: 'dsh-ss' },
            h('div', { className: 'dsh-ss-err' }, '这个插件没有声明可配置项，配置表单不可用。'));
        }

        const values = valuesOf(form);

        return h('div', { className: 'dsh-ss', 'data-dsh-native-tools-settings': '' },
          this.renderCard(FEATURES[0], values.screenshot.enabled, writable, this.renderScreenshot(values.screenshot.enabled, writable)),
          this.renderCard(FEATURES[1], values.clipboard.enabled, writable, this.renderClipboard(values.clipboard.enabled, writable)),
          this.renderCard(FEATURES[2], values.translate.enabled, writable, this.renderTranslate(values.translate.enabled, writable)),
          this.renderCard(FEATURES[3], values.monitor.enabled, writable, this.renderMonitor(values.monitor.enabled, writable)),
          this.state.error !== '' ? h('div', { className: 'dsh-ss-err' }, this.state.error) : null,
          this.state.saved !== '' ? h('div', { className: 'dsh-ss-ok' }, this.state.saved) : null,
          h('div', { className: 'dsh-ss-hint' },
            '四个功能跑在同一个原生进程里：改动立刻生效（装/卸对应功能），不需要重启 DSH。'),
        );
      }
    }

    /** 槽位组件：`view` 决定画摘要还是完整页。 */
    function RowConfig(props) {
      try {
        if (props.view === 'summary') return h(SummaryRow, { form: props.form });
        return h(SettingsPage, { form: props.form });
      } catch (error) {
        const message = error && error.message ? error.message : String(error);
        try { console.error('[dsh-native-tools] settings render failed:', error); } catch { /* ignore */ }
        return h('div', { className: 'dsh-ss-err' }, message);
      }
    }

    /** 把 `ctx.configForms` 的控制器包装成 SettingsPage 需要的 `{ state, mutate }`。 */
    function formAdapter(controller) {
      return {
        get state() { return controller.getSnapshot(); },
        mutate: (ops, revision) => controller.mutate(ops, revision),
      };
    }

    /**
     * 插件详情页（bundle 级）的配置区桥接。
     *
     * `plugins.row.config` 的 owner 会把 `form` 直接给进来，但 bundle 槽只传
     * `{ view: 'page' }`（见 plugin-manager 的 PackageDetail：renderSlot(
     * 'plugins.bundle.config', { view: 'page' }, { entryKey: pkg.name })）。
     * 所以这里自己去 `ctx.configForms` 取同一个控制器，订阅它的快照后复用
     * 同一个 SettingsPage —— 用户从「插件 › 原生助手」进来看的就是这一页。
     */
    class BundleConfigBridge extends React.Component {
      constructor(props) {
        super(props);
        this.controller = props.form === undefined ? props.controller : undefined;
        this.form = props.form ?? (this.controller ? formAdapter(this.controller) : undefined);
        this.state = { revision: 0 };
      }

      componentDidMount() {
        if (this.controller === undefined) return;
        this.unsubscribe = this.controller.subscribe(() => {
          this.setState((previous) => ({ revision: previous.revision + 1 }));
        });
      }

      componentWillUnmount() {
        if (this.unsubscribe !== undefined) {
          this.unsubscribe();
          this.unsubscribe = undefined;
        }
      }

      render() {
        if (this.form === undefined) {
          return h('div', { className: 'dsh-ss-err' },
            '配置表单还没准备好：这个插件的 Config 没有出现在设置命名空间里。');
        }
        return h(RowConfig, { view: this.props.view ?? 'page', form: this.form });
      }
    }

    return {
      inject: ['slots', 'configForms'],
      apply(ctx) {
        ctx.effect(() => mountStyles(), 'dsh-native-tools: settings styles');
        ctx.slots.inject('plugins.row.config', () => ctx.slots.register({
          name: 'plugins.row.config',
          key: CONFIG_KEY,
          id: `${ROW_ID}-settings`,
          order: 50,
        }, RowConfig));
        // 插件详情页那一条：plugin-manager 只在这里渲染 key === 包名的槽，
        // 没有它就等于「这个插件没有配置」——三个开关也就无处可显示。
        ctx.slots.inject('plugins.bundle.config', () => ctx.slots.register({
          name: 'plugins.bundle.config',
          key: PACKAGE,
          id: `${ROW_ID}-bundle-settings`,
          order: 50,
        }, (props) => h(BundleConfigBridge, {
          view: props.view,
          controller: ctx.configForms.get(ROW_ID),
        })));
      },
    };
  },
});
