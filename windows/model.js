const defaults = {
  theme: 'system', sound: true, lamp: true, pinned: false,
  font: 'print', fontSize: 19, spacing: 0, paper: 'plain', ink: 'original',
  lampColor: 'neutral', lampIntensity: 75, lampRange: 100,
};

function dayKey(date = new Date()) {
  return [date.getFullYear(), date.getMonth() + 1, date.getDate()]
    .map((value, index) => String(value).padStart(index ? 2 : 4, '0')).join('-');
}

function progress(rows) {
  const tasks = rows.filter(row => row.text.trim());
  return { done: tasks.filter(row => row.done).length, total: tasks.length };
}

function normalize(snapshot) {
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) {
    throw new Error('便签文件的格式不正确');
  }
  if (!snapshot.plans || typeof snapshot.plans !== 'object' || Array.isArray(snapshot.plans)) {
    throw new Error('便签记录的格式不正确');
  }
  const plans = Object.fromEntries(Object.entries(snapshot.plans).flatMap(([day, rows]) => {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day) || !Array.isArray(rows) || rows.some(row =>
      !row || typeof row.id !== 'string' || typeof row.text !== 'string' || typeof row.done !== 'boolean' ||
      (row.parentID != null && typeof row.parentID !== 'string'))) {
      throw new Error('便签记录的格式不正确');
    }
    const kept = rows.filter(row => row.parentID == null || row.text.trim()).map(row => ({
      id: row.id, text: row.text, done: row.done, ...(row.parentID ? { parentID: row.parentID } : {}),
    }));
    return kept.some(row => row.text.trim()) ? [[day, kept]] : [];
  }));
  const preferences = {};
  for (const [key, fallback] of Object.entries(defaults)) {
    const value = snapshot.preferences?.[key];
    preferences[key] = typeof value === typeof fallback ? value : fallback;
  }
  return { plans, preferences };
}

function newRow(text = '', parentID) {
  return { id: globalThis.crypto.randomUUID(), text, done: false, ...(parentID ? { parentID } : {}) };
}

const paperModel = { dayKey, defaults, newRow, normalize, progress };
if (typeof module !== 'undefined') module.exports = paperModel;
