'use strict'

const fs = require('fs')
const path = require('path')

/**
 * Antora extension that exports AsciiDoc content with resolved attributes
 * for RAG (Retrieval Augmented Generation) purposes.
 *
 * This extension intercepts the Antora build process after attribute substitution
 * but before HTML rendering, giving you access to the "user-facing" content.
 */
module.exports.register = function ({ config }) {
  const logger = this.getLogger('rag-export-extension')

  // Default configuration
  const outputDir = config.outputDir || './rag-content'
  const enabled = config.enabled !== false

  if (!enabled) {
    logger.info('RAG export is disabled')
    return
  }

  this.on('documentsConverted', ({ contentCatalog, siteCatalog }) => {
    logger.info('Exporting documents with resolved attributes for RAG...')

    // Create output directory if it doesn't exist
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true })
    }

    // Get all page documents
    const pages = contentCatalog.findBy({ family: 'page' })
    let exportedCount = 0

    pages.forEach((page) => {
      // Skip special files if needed
      const filename = page.src.basename
      if (filename === 'ai-chatbot.adoc' || filename === 'nav.adoc' || filename === 'attrs-page.adoc') {
        return
      }

      try {
        // Access the Asciidoctor document object
        const doc = page.asciidoc

        if (!doc) {
          logger.warn(`No AsciiDoc document for ${page.src.relative}`)
          return
        }

        // Get title - Antora stores this in the page object
        const title = page.asciidoc.doctitle || page.title || page.src.stem

        // Get attributes - stored in the asciidoc attributes object
        const attributes = page.asciidoc.attributes || {}

        // Get the source with attribute substitution
        const resolvedContent = resolveAttributesInSource(page, attributes, logger)

        // Create metadata header
        const metadata = {
          title: title,
          component: page.src.component,
          version: page.src.version,
          module: page.src.module,
          originalPath: page.src.relative,
          url: page.pub?.url || '',
          relevantAttributes: extractRelevantAttributes(attributes)
        }

        // Combine metadata and content
        const output = `---
METADATA:
${JSON.stringify(metadata, null, 2)}
---

${resolvedContent}
`

        // Generate output filename
        const outputFilename = `${page.src.component}-${page.src.module}-${page.src.stem}.txt`
        const outputPath = path.join(outputDir, outputFilename)

        // Write to file
        fs.writeFileSync(outputPath, output, 'utf-8')
        exportedCount++

        logger.debug(`Exported: ${outputFilename}`)

      } catch (error) {
        logger.error(`Error exporting ${page.src.relative}: ${error.message}`)
        logger.error(error.stack)
      }
    })

    logger.info(`Successfully exported ${exportedCount} documents to ${outputDir}`)
  })
}

/**
 * Resolve attributes in the original source
 * This reads the original .adoc file and manually substitutes attributes
 */
function resolveAttributesInSource(page, attributes, logger) {
  try {
    // Try to find the original source file
    // The page.src.origin.worktree gives us the base directory
    const worktree = page.src.origin?.worktree
    const startPath = page.src.origin?.startPath || ''

    if (!worktree) {
      logger.warn(`No worktree found for ${page.src.relative}, using HTML fallback`)
      return htmlToText(page.contents.toString('utf-8'))
    }

    // Build the full path to the source file
    // Antora structure: worktree/startPath/modules/MODULE/pages/file.adoc
    const modulePath = page.src.module || 'ROOT'
    const familyPlural = page.src.family === 'page' ? 'pages' : page.src.family + 's'
    const fullPath = path.join(worktree, startPath, 'modules', modulePath, familyPlural, page.src.relative)

    if (!fs.existsSync(fullPath)) {
      logger.warn(`Source file not found at ${fullPath}, using HTML fallback`)
      return htmlToText(page.contents.toString('utf-8'))
    }

    // Read the original source file
    let content = fs.readFileSync(fullPath, 'utf-8')

    // Substitute attributes
    // AsciiDoc attribute syntax is {attribute_name}
    Object.keys(attributes).forEach(key => {
      const value = attributes[key]
      if (typeof value === 'string') {
        // Replace all occurrences of {key} with the value
        const regex = new RegExp(`\\{${escapeRegex(key)}\\}`, 'g')
        content = content.replace(regex, value)
      }
    })

    return content
  } catch (error) {
    logger.warn(`Error reading source for ${page.src.relative}: ${error.message}, using HTML fallback`)
    // Fallback: return HTML converted to text
    const htmlContent = page.contents.toString('utf-8')
    return htmlToText(htmlContent)
  }
}

/**
 * Escape special regex characters in a string
 */
function escapeRegex(string) {
  return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * Simple HTML to text conversion (fallback)
 */
function htmlToText(html) {
  let text = html

  // Remove scripts and styles
  text = text.replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, '')
  text = text.replace(/<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>/gi, '')

  // Replace common HTML entities
  text = text.replace(/&nbsp;/g, ' ')
  text = text.replace(/&#8217;/g, "'")
  text = text.replace(/&#8220;/g, '"')
  text = text.replace(/&#8221;/g, '"')
  text = text.replace(/&quot;/g, '"')
  text = text.replace(/&apos;/g, "'")
  text = text.replace(/&amp;/g, '&')
  text = text.replace(/&lt;/g, '<')
  text = text.replace(/&gt;/g, '>')

  // Remove HTML tags
  text = text.replace(/<[^>]+>/g, ' ')

  // Clean up whitespace
  text = text.replace(/\s+/g, ' ')
  text = text.replace(/\n\s*\n/g, '\n\n')

  return text.trim()
}

/**
 * Extract relevant attributes that were used in the document
 */
function extractRelevantAttributes(attributes) {
  const attrs = {}

  // Common workshop attributes
  const relevantAttrs = [
    'lab_name', 'guid', 'ssh_user', 'ssh_password', 'ssh_command',
    'release-version', 'workshop_title', 'assistant_name',
    'my_var', 'welcome_message'
  ]

  relevantAttrs.forEach(attr => {
    const value = attributes[attr]
    if (value !== undefined && typeof value === 'string') {
      attrs[attr] = value
    }
  })

  return attrs
}
