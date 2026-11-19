(() => {
  const { dayKey, newRow, progress } = paperModel;
  const $ = id => document.getElementById(id);
  const ui = Object.fromEntries(['shell', 'archive', 'note', 'date', 'progress', 'scroll', 'sheet', 'tasks',
    'light', 'rail', 'typehead', 'library', 'calendar', 'month', 'month-number', 'settings', 'status']
    .map(id => [id, $(id)]));
  const api = window.paperframe;
  const systemTheme = matchMedia('(prefers-color-scheme: dark)');
  const measure = document.createElement('div');
  measure.id = 'measure';
  measure.setAttribute('aria-hidden', 'true');
  ui.sheet.append(measure);
  const clickSound = new Audio('/assets/strike.wav');
  const returnSound = new Audio('/assets/return.wav');
  let soundTimer;
  let state;
  let day;
  let month;
  let rows = [];
  let activeId;
  let dragId;
  let drop;
  const collapsed = new Set();

  function save() {
    const written = rows.filter(row => !row.parentID || row.text.trim());
    if (written.some(row => row.text.trim())) state.plans[day] = written;
    else delete state.plans[day];
    api.save(state).catch(error => {
      ui.status.textContent = '保存失败。' + error.message;
      ui.status.hidden = false;
    });
    if (!ui.archive.hidden) updateCalendar();
    updateProgress();
  }

  function applyPreferences() {
    const prefs = state.preferences;
    const root = document.documentElement;
    root.dataset.theme = prefs.theme === 'system' ? (systemTheme.matches ? 'night' : 'day') : prefs.theme;
    root.dataset.paper = prefs.paper;
    root.dataset.ink = prefs.ink;
    root.dataset.font = prefs.font;
    root.toggleAttribute('data-lamp', prefs.lamp);
    root.style.setProperty('--font-size', prefs.fontSize + 'px');
    root.style.setProperty('--row-spacing', prefs.spacing + 'px');
    root.style.setProperty('--lamp-intensity', prefs.lampIntensity / 100);
    root.style.setProperty('--lamp-range', prefs.lampRange / 100);
    root.style.setProperty('--lamp-color', { neutral: '#fff4db', warm: '#ffcd90', cool: '#a6cbff' }[prefs.lampColor] ?? '#fff4db');
    for (const input of document.querySelectorAll('[data-pref]')) {
      const value = prefs[input.dataset.pref];
      if (input.type === 'checkbox') input.checked = value;
      else input.value = value;
    }
    fitRows();
  }

  function play(returning = false) {
    ui.typehead.classList.remove('strike');
    void ui.typehead.offsetWidth;
    ui.typehead.classList.add('strike');
    if (!state.preferences.sound) return;
    const audio = returning ? returnSound : clickSound;
    audio.currentTime = 0;
    audio.volume = returning ? .40 : .52;
    audio.play().catch(() => {});
    if (returning) {
      clearTimeout(soundTimer);
      soundTimer = setTimeout(() => returnSound.pause(), 480);
    }
  }

  function openDate(key) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(key)) return;
    day = key;
    month = key.slice(0, 7);
    rows = (state.plans[key] ?? []).map(row => ({ ...row }));
    if (!rows.length) rows.push(newRow());
    activeId = rows.findLast(row => !collapsed.has(row.parentID))?.id;
    ui.date.value = key;
    ui.scroll.scrollTop = 0;
    renderRows();
    updateCalendar();
  }

  function updateCalendar() {
    const [year, currentMonth] = month.split('-').map(Number);
    const first = new Date(year, currentMonth - 1, 1);
    const offset = (first.getDay() + 6) % 7;
    const length = new Date(year, currentMonth, 0).getDate();
    ui.month.value = month;
    ui['month-number'].textContent = month.slice(5);
    ui.calendar.replaceChildren();
    for (let index = 0; index < 42; index++) {
      const number = index - offset + 1;
      if (number < 1 || number > length) {
        ui.calendar.append(document.createElement('span'));
        continue;
      }
      const key = month + '-' + String(number).padStart(2, '0');
      const button = document.createElement('button');
      const recorded = Boolean(state.plans[key]?.some(row => row.text.trim()));
      button.type = 'button';
      button.textContent = number;
      button.setAttribute('aria-label', key + (recorded ? '，有便签' : ''));
      button.setAttribute('aria-pressed', String(key === day));
      if (key === dayKey()) button.setAttribute('aria-current', 'date');
      if (recorded) {
        button.className = 'recorded';
        button.append(document.createElement('i'));
      }
      button.onclick = () => openDate(key);
      ui.calendar.append(button);
    }
  }

  function updateProgress() {
    const counts = progress(rows);
    ui.progress.textContent = '已完成 ' + counts.done + ' / ' + counts.total;
  }

  function control(title, text, onClick) {
    const button = document.createElement('button');
    button.type = 'button';
    button.title = title;
    button.setAttribute('aria-label', title);
    button.textContent = text;
    button.onpointerdown = event => event.preventDefault();
    button.onclick = onClick;
    return button;
  }

  function endOfGroup(index) {
    if (rows[index].parentID) return index + 1;
    const parent = rows[index].id;
    let next = index + 1;
    while (rows[next]?.parentID === parent) next++;
    return next;
  }

  function renderRows(focusId, caret) {
    ui.tasks.replaceChildren();
    const withChildren = new Set(rows.flatMap(row => row.parentID && row.text.trim() ? [row.parentID] : []));
    for (const row of rows) {
      if (collapsed.has(row.parentID)) continue;
      const item = document.createElement('li');
      item.className = 'task' + (row.parentID ? ' child' : '') + (row.done ? ' done' : '');
      item.dataset.row = row.id;
      item.classList.toggle('active', activeId === row.id);
      const handle = document.createElement('span');
      handle.className = 'handle';
      handle.textContent = '⠿';
      handle.title = '上下拖动调整顺序';
      handle.draggable = row.text.trim().length > 0;
      handle.ondragstart = event => {
        dragId = row.id;
        event.dataTransfer.effectAllowed = 'move';
        event.dataTransfer.setData('text/plain', row.id);
        event.dataTransfer.setDragImage(item, 10, 12);
        requestAnimationFrame(() => { if (dragId === row.id) item.classList.add('dragged'); });
      };
      handle.ondragend = clearDrop;
      const check = document.createElement('input');
      check.type = 'checkbox';
      check.checked = row.done;
      check.setAttribute('aria-label', '完成任务');
      check.disabled = Boolean(row.parentID && !row.text.trim());
      check.onchange = () => {
        row.done = check.checked;
        item.classList.toggle('done', row.done);
        save();
      };
      const input = document.createElement('textarea');
      input.rows = 1;
      input.value = row.text;
      input.spellcheck = false;
      input.setAttribute('aria-label', row.parentID ? '子任务文字' : '任务文字');
      input.onfocus = () => { activeId = row.id; follow(input); };
      input.onblur = () => {
        if (row.parentID && !row.text.trim()) {
          queueMicrotask(() => {
            if (input.isConnected && document.activeElement !== input && !row.text.trim()) discardDraft(row);
          });
        }
      };
      input.onkeydown = event => editKey(event, row);
      const actions = document.createElement('div');
      actions.className = 'actions';
      const plus = control('添加子任务', '+', () => addChild(row));
      if (!row.parentID) {
        if (withChildren.has(row.id)) {
          const closed = collapsed.has(row.id);
          const toggle = control(closed ? '展开子任务' : '收起子任务', closed ? '›' : '⌄', () => fold(row));
          toggle.setAttribute('aria-expanded', String(!closed));
          actions.append(toggle);
        }
        plus.disabled = !row.text.trim();
        actions.append(plus);
      }
      const changed = event => {
        if (event?.isComposing) return;
        const hadText = Boolean(row.text.trim());
        row.text = input.value;
        plus.disabled = !row.text.trim();
        check.disabled = Boolean(row.parentID && !row.text.trim());
        handle.draggable = Boolean(row.text.trim());
        if (row.parentID && hadText !== Boolean(row.text.trim())) {
          renderRows(row.id, input.selectionStart);
        } else {
          fit(input);
          follow(input);
        }
        play();
        save();
      };
      input.oninput = changed;
      input.oncompositionend = changed;
      input.onkeyup = () => follow(input);
      input.onclick = () => follow(input);
      item.append(handle, check, input, actions);
      ui.tasks.append(item);
    }
    fitRows();
    if (focusId) {
      const input = ui.tasks.querySelector('[data-row="' + focusId + '"] textarea');
      if (input) {
        input.focus({ preventScroll: true });
        const position = caret ?? input.value.length;
        input.setSelectionRange(position, position);
        input.closest('.task').scrollIntoView({ block: 'nearest' });
        follow(input);
      }
    }
    updateProgress();
  }

  function fit(input) {
    input.style.height = '0px';
    input.style.height = input.scrollHeight + 'px';
  }

  function fitRows() {
    if (!state) return;
    ui.tasks.querySelectorAll('textarea').forEach(fit);
    const active = ui.tasks.querySelector('.active textarea');
    if (active) follow(active);
  }

  function follow(input) {
    if (!input.isConnected) return;
    const item = input.closest('.task');
    if (item.dataset.row !== activeId) return;
    for (const next of ui.tasks.querySelectorAll('.task')) next.classList.toggle('active', next === item);
    measure.style.width = input.clientWidth + 'px';
    const mark = document.createElement('span');
    mark.textContent = '\u200b';
    const caret = input.selectionStart;
    measure.replaceChildren(document.createTextNode(input.value.slice(0, caret)), mark,
      document.createTextNode(input.value.slice(caret)));
    const paper = ui.sheet.getBoundingClientRect();
    const text = input.getBoundingClientRect();
    const measured = mark.getBoundingClientRect().left - measure.getBoundingClientRect().left;
    const x = text.left - paper.left + measured;
    const y = text.bottom - paper.top + 22;
    ui.rail.style.setProperty('--rail-y', y + 'px');
    ui.typehead.style.setProperty('--head-x', Math.max(0, Math.min(ui.rail.clientWidth - 64, x - 50)) + 'px');
    ui.light.style.setProperty('--lamp-x', x + 'px');
    ui.light.style.setProperty('--lamp-y', y + 'px');
  }

  function addChild(anchor) {
    const parent = anchor.parentID ?? anchor.id;
    const index = rows.findIndex(row => row.id === parent);
    collapsed.delete(parent);
    let child = rows.find(row => row.parentID === parent && !row.text.trim());
    if (!child) {
      child = newRow('', parent);
      rows.splice(endOfGroup(index), 0, child);
    }
    activeId = child.id;
    renderRows(child.id);
  }

  function discardDraft(row, returnToParent = false) {
    if (!row.parentID || row.text.trim() || !rows.includes(row)) return;
    rows.splice(rows.indexOf(row), 1);
    const current = document.activeElement;
    if (activeId === row.id) activeId = row.parentID;
    const editing = current?.tagName === 'TEXTAREA' && current.closest('.task')?.dataset.row !== row.id;
    renderRows(returnToParent ? row.parentID : (editing ? activeId : undefined), editing ? current.selectionStart : undefined);
  }

  function fold(row) {
    if (collapsed.delete(row.id)) {
      renderRows();
      return;
    }
    collapsed.add(row.id);
    const wasEditingChild = rows.find(task => task.id === activeId)?.parentID === row.id;
    if (wasEditingChild) activeId = row.id;
    rows = rows.filter(task => task.parentID !== row.id || task.text.trim());
    renderRows(wasEditingChild ? row.id : undefined);
  }

  function editKey(event, row) {
    if (event.isComposing || event.keyCode === 229) return;
    const input = event.currentTarget;
    const { selectionStart: start, selectionEnd: end } = input;
    const index = rows.indexOf(row);
    if (event.key === 'Enter') {
      event.preventDefault();
      if (event.ctrlKey || event.metaKey) {
        if (row.text.trim()) addChild(row);
        return;
      }
      const preceding = row.text.slice(0, start);
      if (row.parentID && !preceding.trim()) return;
      const next = newRow(row.text.slice(end), row.parentID);
      row.text = preceding;
      rows.splice(endOfGroup(index), 0, next);
      activeId = next.id;
      renderRows(next.id, 0);
      play(true);
      save();
    } else if (event.key === 'Escape' && row.parentID && !row.text.trim()) {
      event.preventDefault();
      discardDraft(row, true);
    } else if (event.key === 'Backspace' && start === 0 && end === 0 && index > 0) {
      event.preventDefault();
      if (row.parentID) {
        discardDraft(row, true);
        return;
      }
      const previous = rows.slice(0, index).findLast(task => !task.parentID);
      if (!previous) return;
      const position = previous.text.length;
      previous.text += row.text;
      rows.splice(index, 1);
      rows.forEach(task => { if (task.parentID === row.id) task.parentID = previous.id; });
      activeId = previous.id;
      renderRows(previous.id, position);
      save();
    }
  }

  function clearDrop() {
    dragId = undefined;
    drop = undefined;
    ui.tasks.querySelectorAll('.dragged, .before, .after').forEach(item =>
      item.classList.remove('dragged', 'before', 'after'));
  }

  function installControls() {
    ui.tasks.ondragover = event => {
      const item = event.target.closest('.task');
      const source = rows.find(row => row.id === dragId);
      const target = rows.find(row => row.id === item?.dataset.row);
      ui.tasks.querySelectorAll('.before, .after').forEach(row => row.classList.remove('before', 'after'));
      drop = undefined;
      if (!source || !target || target.id === source.id || target.parentID !== source.parentID) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = 'move';
      const box = item.getBoundingClientRect();
      const after = event.clientY > box.top + Math.min(box.height, 26) / 2;
      item.classList.add(after ? 'after' : 'before');
      drop = { target: target.id, after };
    };
    ui.tasks.ondrop = event => {
      if (!drop || !dragId) return;
      event.preventDefault();
      const source = rows.findIndex(row => row.id === dragId);
      const moved = rows.splice(source, endOfGroup(source) - source);
      const target = rows.findIndex(row => row.id === drop.target);
      rows.splice(drop.after ? endOfGroup(target) : target, 0, ...moved);
      clearDrop();
      renderRows();
      save();
    };
    ui.date.onchange = () => openDate(ui.date.value);
    ui.month.onchange = () => {
      if (/^\d{4}-\d{2}$/.test(ui.month.value)) {
        month = ui.month.value;
        updateCalendar();
      }
    };
    function shiftMonth(offset) {
      const [y, m] = month.split('-').map(Number);
      month = dayKey(new Date(y, m + offset - 1, 1)).slice(0, 7);
      updateCalendar();
    }
    $('previous').onclick = () => shiftMonth(-1);
    $('next').onclick = () => shiftMonth(1);
    $('today').onclick = () => openDate(dayKey());
    $('new-task').onclick = () => {
      const root = newRow();
      rows.push(root);
      activeId = root.id;
      renderRows(root.id);
    };
    ui.library.onclick = () => {
      const open = ui.archive.hidden;
      ui.archive.hidden = !open;
      ui.settings.hidden = !open;
      ui.progress.hidden = !open;
      ui.shell.toggleAttribute('data-library', open);
      ui.library.textContent = open ? '返回便签' : '便签档案';
      $('settings-button').setAttribute('aria-expanded', String(open));
      api.library(open).catch(() => {});
      updateCalendar();
      requestAnimationFrame(fitRows);
    };
    $('settings-button').onclick = () => {
      ui.settings.hidden = !ui.settings.hidden;
      $('settings-button').setAttribute('aria-expanded', String(!ui.settings.hidden));
      requestAnimationFrame(fitRows);
    };
    for (const input of document.querySelectorAll('[data-pref]')) {
      input.oninput = () => {
        const value = input.type === 'checkbox' ? input.checked : input.type === 'range' ? input.valueAsNumber : input.value;
        state.preferences[input.dataset.pref] = value;
        if (input.dataset.pref === 'pinned') api.pin(value).catch(() => {});
        applyPreferences();
        save();
      };
    }
    systemTheme.addEventListener('change', applyPreferences);
    new ResizeObserver(fitRows).observe(ui.scroll);
    document.fonts.ready.then(fitRows);
  }

  api.load().then(snapshot => {
    state = snapshot;
    installControls();
    openDate(dayKey());
    applyPreferences();
    api.pin(state.preferences.pinned).catch(() => {});
  }).catch(error => {
    ui.status.textContent = '读取便签失败。' + error.message;
    ui.status.hidden = false;
  });
})();
