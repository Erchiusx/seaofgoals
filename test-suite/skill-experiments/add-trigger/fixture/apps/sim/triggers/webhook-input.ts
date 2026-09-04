export function formatWebhookInput(provider: string, payload: any) {
  if (provider === 'slack') {
    return { text: payload.text };
  }

  return payload;
}

