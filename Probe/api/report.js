module.exports = (req, res) => {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    res.status(405).json({ ok: false, error: 'method not allowed' });
    return;
  }

  var body = req.body;

  if (Buffer.isBuffer(body)) {
    body = body.toString('utf8');
  }
  if (typeof body === 'string') {
    try {
      body = body.length ? JSON.parse(body) : {};
    } catch (e) {
      body = { raw: body };
    }
  }
  if (!body || typeof body !== 'object') {
    body = {};
  }

  console.log('PROBE_REPORT ' + JSON.stringify(body));

  res.status(200).json({ ok: true });
};
