const API = {
  async health() {
    const response = await fetch('/api/health');
    return parseResponse(response);
  },

  async createReport(payload) {
    const response = await fetch('/api/reports', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    });
    return parseResponse(response);
  }
};

async function parseResponse(response) {
  let body = null;
  try { body = await response.json(); } catch (_) {}
  if (!response.ok) {
    throw new Error(body?.error || `Request failed (${response.status})`);
  }
  return body;
}
