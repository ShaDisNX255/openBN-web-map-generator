const generate = require('./generate');

(async () => {
  const link = process.argv[2];
  const isHomePage = process.argv[3] === 'true';

  try {
    const result = await generate(link, isHomePage);
    if (process.send) {
      process.send({ ok: true, result });
    } else {
      console.log(JSON.stringify({ ok: true, result }));
    }
    process.exit(0);
  } catch (error) {
    const payload = {
      ok: false,
      error: error?.message || String(error),
      stack: error?.stack || null
    };

    if (process.send) {
      process.send(payload);
    } else {
      console.error(JSON.stringify(payload));
    }
    process.exit(1);
  }
})();
