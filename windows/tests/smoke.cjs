const { _electron: electron } = require('playwright-core');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');

async function run() {
  const data = await fs.mkdtemp(path.join(os.tmpdir(), 'paperframe-smoke-'));
  const requestedExecutable = process.argv[2];
  const launch = () => electron.launch({
    ...(requestedExecutable ? { executablePath: path.resolve(requestedExecutable), args: [] } :
      { args: [path.resolve(__dirname, '..')] }),
    env: { ...process.env, PAPERFRAME_TEST_DATA: data },
  });
  let app;
  try {
    app = await launch();
    let page = await app.firstWindow();
    const task = page.getByRole('textbox', { name: '任务文字', exact: true });
    const child = page.getByRole('textbox', { name: '子任务文字', exact: true });
    await task.waitFor();
    const date = await page.locator('#date').inputValue();
    await task.fill('写完周报');
    await page.getByRole('button', { name: '添加子任务', exact: true }).click();
    await child.press('Enter');
    assert.equal(await child.count(), 1);
    await child.fill('核对数字');
    await page.locator('.task.child input[type=checkbox]').check();
    await page.getByRole('button', { name: '收起子任务', exact: true }).click();
    assert.equal(await child.count(), 0);
    await page.getByRole('button', { name: '展开子任务', exact: true }).click();
    assert.equal(await child.inputValue(), '核对数字');
    await task.press('End');
    await task.press('Enter');
    const tasks = page.getByRole('textbox', { name: '任务文字', exact: true });
    await tasks.nth(1).fill('整理桌面');
    await page.locator('.task').last().locator('.handle').dragTo(page.locator('.task').first(), {
      targetPosition: { x: 48, y: 3 },
    });
    assert.equal(await tasks.first().inputValue(), '整理桌面');

    await page.getByRole('button', { name: '便签档案', exact: true }).click();
    await page.getByRole('button', { name: date + '，有便签', exact: true }).waitFor();
    await page.locator('[data-pref=theme]').selectOption('night');
    await page.waitForFunction(() => document.documentElement.dataset.theme === 'night');
    assert.match(await page.locator('#progress').textContent(), /已完成 1 \/ 3/);
    await app.close();
    app = undefined;

    app = await launch();
    page = await app.firstWindow();
    await page.getByRole('textbox', { name: '子任务文字', exact: true }).waitFor();
    assert.equal(await page.getByRole('textbox', { name: '任务文字', exact: true }).first().inputValue(), '整理桌面');
    assert.equal(await page.locator('.task.child textarea').inputValue(), '核对数字');
    assert.equal(await page.locator('.task.child input[type=checkbox]').isChecked(), true);
    assert.equal(await page.locator('html').getAttribute('data-theme'), 'night');
    assert.equal(await page.locator('#status').isVisible(), false);
    console.log('Paperframe smoke passed: editing, subtask folding, drag sorting, calendar, night mode and persistence.');
  } finally {
    if (app) await app.close();
    await fs.rm(data, { recursive: true, force: true, maxRetries: 4, retryDelay: 150 });
  }
}

run().catch(error => { console.error(error); process.exitCode = 1; });
