# Rules and limits

Free models may use prompts for training, so do not send confidential or personal data.

Each key is limited to 10 requests per minute. If you see a 429 error you have hit the rate limit:
wait a minute and retry. The openai library retries automatically with a short delay.

Each key also has a budget for paid fallback models, refilled every 30 days. Free models never count
against the budget. When the budget is used up you get a "Budget has been exceeded" error until it resets.

Keys expire after 90 days. Ask the instructor for a new key if yours is lost or leaked.
