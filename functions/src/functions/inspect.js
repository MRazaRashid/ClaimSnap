const { app } = require('@azure/functions');
const { inspectImage } = require('../image');

// Called by the IUPS Logic App before anything is stored.
// Body: { fileName, data } where data is the photo as base64.
app.http('inspect', {
  methods: ['POST'],
  authLevel: 'function',
  handler: async (request, context) => {
    const body = await request.json().catch(() => null);
    if (typeof body?.data !== 'string') {
      return { status: 400, jsonBody: { error: 'Request body must include the photo as base64 in "data"' } };
    }

    const result = await inspectImage(Buffer.from(body.data, 'base64'));
    context.log(`inspect ${body.fileName ?? 'unnamed'}: ${result.status}`, result.body.sha256 ?? result.body.error);
    return { status: result.status, jsonBody: result.body };
  },
});
