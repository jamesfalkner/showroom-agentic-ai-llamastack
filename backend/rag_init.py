#!/usr/bin/env python3
"""
RAG Initialization Module
Loads documents and uploads them to LlamaStack vector store
"""
import logging
import tempfile
import re
import json
from pathlib import Path
from typing import List
from PyPDF2 import PdfReader

logger = logging.getLogger(__name__)


async def initialize_vector_store(client, content_dir: str, pdf_dir: str, min_chunk_size: int = 100, embedding_model: str = "text-embedding-3-small"):
    """
    Initialize LlamaStack vector store with workshop documents

    Args:
        client: LlamaStackClient instance
        content_dir: Path to AsciiDoc content directory
        pdf_dir: Path to PDF documentation directory
        min_chunk_size: Minimum size for document chunks
        embedding_model: Embedding model to use (e.g., "text-embedding-3-small")

    Returns:
        vector_store_id: ID of created/existing vector store
    """
    vector_store_id = "workshop-docs"

    # Check if vector store already exists
    try:
        stores = client.vector_stores.list()
        existing_store = next((s for s in stores.data if s.id == vector_store_id or s.name == vector_store_id), None)

        if existing_store:
            logger.info(f"Using existing vector store: {existing_store.id}")
            return existing_store.id
    except Exception as e:
        logger.warning(f"Error checking existing vector stores: {e}")

    # Create vector store with configured embedding model
    try:
        logger.info(f"Creating vector store '{vector_store_id}' with embedding model: {embedding_model}...")
        vector_store = client.vector_stores.create(
            name=vector_store_id,
            extra_body={
                "embedding_model": embedding_model
            }
        )
        logger.info(f"Created vector store: {vector_store.id}")
        vector_store_id = vector_store.id
    except Exception as e:
        logger.error(f"Failed to create vector store: {e}")
        return None

    # Load and upload documents
    try:
        # Collect all document content
        all_content = []

        # Load AsciiDoc content
        content_path = Path(content_dir)
        if content_path.exists():
            adoc_content = _load_asciidoc_content(content_path, min_chunk_size)
            all_content.extend(adoc_content)
            logger.info(f"Loaded {len(adoc_content)} AsciiDoc documents")

        # Load PDF content
        pdf_path = Path(pdf_dir)
        if pdf_path.exists():
            pdf_content = _load_pdf_content(pdf_path, min_chunk_size)
            all_content.extend(pdf_content)
            logger.info(f"Loaded {len(pdf_content)} PDF documents")

        if not all_content:
            logger.warning("No documents found to upload")
            return vector_store_id

        # Upload each document individually to preserve metadata for citations
        uploaded_count = 0
        for doc in all_content:
            try:
                # Create individual file with metadata header
                doc_text = f"[{doc['module']} - {doc['title']}]\n"
                doc_text += f"Source: {doc['file_path']}\n\n"
                doc_text += doc['content']

                # Create temporary file
                with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, encoding='utf-8') as f:
                    f.write(doc_text)
                    temp_file = f.name

                try:
                    # Step 1: Upload file to get file_id
                    with open(temp_file, 'rb') as f:
                        uploaded_file = client.files.create(
                            file=f,
                            purpose='assistants'
                        )
                        logger.info(f"Uploaded file: {uploaded_file.id} ({doc['title']})")

                    # Step 2: Attach file to vector store
                    file_result = client.vector_stores.files.create(
                        vector_store_id=vector_store_id,
                        file_id=uploaded_file.id
                    )
                    uploaded_count += 1
                    logger.info(f"Attached to vector store: {doc['module']} - {doc['title']}")
                finally:
                    # Clean up temp file
                    Path(temp_file).unlink(missing_ok=True)

            except Exception as e:
                logger.error(f"Error uploading document '{doc['title']}': {e}")
                continue

        logger.info(f"Successfully uploaded {uploaded_count}/{len(all_content)} documents individually")

        return vector_store_id

    except Exception as e:
        logger.error(f"Error uploading documents to vector store: {e}")
        import traceback
        traceback.print_exc()
        return vector_store_id


def _load_asciidoc_content(content_path: Path, min_chunk_size: int) -> List[dict]:
    """
    Load RAG-optimized content files exported by Antora extension.
    These files have resolved AsciiDoc attributes and metadata headers.
    """
    documents = []

    # Check if this is the new RAG content directory (flat structure with .txt files)
    # or the old content directory (modules/ROOT/pages structure with .adoc files)
    txt_files = list(content_path.glob("*.txt"))

    if txt_files:
        # New RAG content format - files with metadata headers
        logger.info(f"Loading RAG-optimized content from {content_path}")
        for exported_file in txt_files:
            # Skip special files
            if exported_file.stem in ['attrs-page', 'ai-chatbot', 'nav']:
                continue

            try:
                content = exported_file.read_text(encoding='utf-8')

                # Parse metadata and content
                if content.startswith('---\nMETADATA:\n'):
                    parts = content.split('---\n', 2)
                    if len(parts) >= 3:
                        metadata_json = parts[1].replace('METADATA:\n', '')
                        metadata = json.loads(metadata_json)
                        actual_content = parts[2].strip()

                        # Clean AsciiDoc markup from the content
                        cleaned_content = _clean_asciidoc(actual_content)

                        if len(cleaned_content.strip()) > min_chunk_size:
                            documents.append({
                                'title': metadata.get('title', exported_file.stem),
                                'content': cleaned_content,
                                'file_path': metadata.get('url', metadata.get('originalPath', str(exported_file))),
                                'module': f"{metadata.get('component', 'modules')} - {metadata.get('module', 'ROOT')}"
                            })
                else:
                    logger.warning(f"File {exported_file} doesn't have expected metadata format")
            except json.JSONDecodeError as e:
                logger.warning(f"Error parsing metadata in {exported_file}: {e}")
            except Exception as e:
                logger.warning(f"Error loading {exported_file}: {e}")
    else:
        # Fallback to old format - raw .adoc files
        logger.info(f"Loading raw AsciiDoc content from {content_path}")
        modules_dir = content_path / "modules" / "ROOT" / "pages"

        if not modules_dir.exists():
            logger.warning(f"No content found at {content_path} or {modules_dir}")
            return documents

        for adoc_file in modules_dir.glob("**/*.adoc"):
            # Skip special files
            if adoc_file.name in ['ai-chatbot.adoc', 'nav.adoc', 'attrs-page.adoc']:
                continue

            try:
                content = adoc_file.read_text(encoding='utf-8')
                title = _extract_title(content, adoc_file.stem)
                cleaned = _clean_asciidoc(content)

                if len(cleaned.strip()) > min_chunk_size:
                    documents.append({
                        'title': title,
                        'content': cleaned,
                        'file_path': str(adoc_file),
                        'module': _extract_module(str(adoc_file))
                    })
            except Exception as e:
                logger.warning(f"Error loading {adoc_file}: {e}")

    return documents


def _load_pdf_content(pdf_path: Path, min_chunk_size: int) -> List[dict]:
    """Load PDF files"""
    documents = []

    for pdf_file in pdf_path.glob("*.pdf"):
        try:
            reader = PdfReader(str(pdf_file))
            text = ""

            for page in reader.pages:
                page_text = page.extract_text()
                if page_text:
                    text += page_text + "\n\n"

            if len(text.strip()) > min_chunk_size:
                title = pdf_file.stem.replace('_', ' ').replace('-', ' ').title()
                # Convert filesystem path to Antora URL path
                # /app/content/modules/ROOT/assets/techdocs/file.pdf -> /_/techdocs/file.pdf
                pdf_url = f"/_/techdocs/{pdf_file.name}"
                documents.append({
                    'title': title,
                    'content': text,
                    'file_path': pdf_url,
                    'module': 'PDF Documentation'
                })
        except Exception as e:
            logger.warning(f"Error loading PDF {pdf_file}: {e}")

    return documents


def _extract_title(content: str, fallback: str) -> str:
    """Extract title from AsciiDoc"""
    for line in content.split('\n'):
        line = line.strip()
        if line.startswith('= ') and not line.startswith('== '):
            return line[2:].strip()
    return fallback.replace('-', ' ').title()


def _clean_asciidoc(content: str) -> str:
    """Clean AsciiDoc markup"""
    lines = []
    in_header = True

    for line in content.split('\n'):
        stripped = line.strip()

        if in_header and (stripped.startswith(':') or stripped.startswith('//') or stripped == ''):
            continue
        in_header = False

        # Remove markup
        cleaned = re.sub(r'^=+\s+', '', line)
        cleaned = re.sub(r'\*([^*]+)\*', r'\1', cleaned)
        cleaned = re.sub(r'_([^_]+)_', r'\1', cleaned)
        cleaned = re.sub(r'`([^`]+)`', r'\1', cleaned)
        cleaned = re.sub(r'link:([^\[]+)\[([^\]]*)\]', r'\2', cleaned)
        cleaned = re.sub(r'image::?[^\[]+\[[^\]]*\]', '', cleaned)

        if cleaned.strip():
            lines.append(cleaned.strip())

    return '\n'.join(lines)


def _extract_module(file_path: str) -> str:
    """Extract module name from path"""
    match = re.search(r'module[-_](\d+)', file_path)
    if match:
        return f"Module {match.group(1)}"
    return "General"
