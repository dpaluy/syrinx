# Parakeet model license review

The pinned model source is:

`FluidInference/parakeet-tdt-0.6b-v3-coreml@aed02740059203c4a87495924f685de3722ae9ce`

The model-card front matter declares `cc-by-4.0`. The rendered license section
states Apache 2.0, and the Hugging Face API license field is empty. These are
materially different redistribution terms.

The native service does not bundle model bytes. It may use a user-installed
model after the owner records an upstream clarification and updates the model
manifest review status. Until then, the release tool must reject a real
release input that has not passed model license review.
