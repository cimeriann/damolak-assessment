const express = require('express');

const app = express();
const port = parseInt(process.env.PORT, 10) || 3000;
const commitSha = process.env.COMMIT_SHA || 'dev';
const startedAt = new Date().toISOString();

app.disable('x-powered-by');

app.get('/', (_req, res) => {
  res.json({
    message: 'Hello from ECS on EC2',
    service: 'assessment-app',
    commit: commitSha,
    startedAt,
  });
});

app.get('/healthz', (_req, res) => {
  res.status(200).json({ status: 'ok' });
});

app.get('/version', (_req, res) => {
  res.json({ commit: commitSha });
});

if (require.main === module) {
  app.listen(port, () => {
    console.log(JSON.stringify({ level: 'info', msg: 'listening', port, commit: commitSha }));
  });
}

module.exports = app;
