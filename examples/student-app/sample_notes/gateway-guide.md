# Using the class AI gateway

Each student gets a personal API key from the instructor. Keys must never be shared, pasted into chat,
or committed to git. Put it in the OPENAI_API_KEY environment variable instead.

The base URL for every request is the class gateway. Any OpenAI-compatible library works, for example
the official openai Python package, LangChain or LlamaIndex.

## Model tiers

The gateway offers three model names. lite is for quick, simple tasks such as classification or short
answers. base is the default for general chat and writing. complex is for reasoning and long documents
and is reserved for the instructor by default.

For retrieval-augmented generation (RAG) use the embed model to turn text into vectors. Always use the
same embedding model for indexing documents and for searching them.
