'use strict'

const { execSync } = require('child_process')
const fs = require('fs')
const path = require('path')

module.exports.register = function ({ config }) {
  const logger = this.getLogger('ai-assistant-build-extension')

  this.on('sitePublished', ({ playbook }) => {
    console.log('Starting AI frontend build process...')

    const projectRoot = path.resolve(__dirname, '../..')
    const frontendDir = path.join(projectRoot, 'frontend')
    const outputDir = playbook.output.dir
    const targetDir = path.join(outputDir, 'ai-assistant')

    try {
      // Check if frontend directory exists
      if (!fs.existsSync(frontendDir)) {
        console.log(`Frontend directory not found at ${frontendDir}, skipping frontend build`)
        return
      }

      // Clean previous Next.js builds
      console.log('Cleaning previous builds...')
      const nextDir = path.join(frontendDir, '.next')
      const outDir = path.join(frontendDir, 'out')

      if (fs.existsSync(nextDir)) {
        fs.rmSync(nextDir, { recursive: true, force: true })
      }
      if (fs.existsSync(outDir)) {
        fs.rmSync(outDir, { recursive: true, force: true })
      }

      // Install dependencies
      console.log('Installing frontend dependencies...')
      execSync('npm install', {
        cwd: frontendDir,
        stdio: 'inherit',
        env: { ...process.env }
      })

      // Build the frontend
      console.log('Building frontend with Next.js...')
      execSync('npm run build', {
        cwd: frontendDir,
        stdio: 'inherit',
        env: { ...process.env }
      })

      // Copy built files to www/ai-assistant
      console.log(`Copying frontend build to ${targetDir}...`)

      // Remove existing target directory if it exists
      if (fs.existsSync(targetDir)) {
        fs.rmSync(targetDir, { recursive: true, force: true })
      }

      // Copy the out directory to the target
      copyRecursiveSync(outDir, targetDir)

      console.log('Frontend build completed successfully!')
      console.log(`Frontend is available at ${targetDir}`)

    } catch (error) {
      logger.error(`Frontend build failed: ${error.message}`)
      throw error
    }
  })
}

/**
 * Recursively copy directory contents
 */
function copyRecursiveSync(src, dest) {
  const exists = fs.existsSync(src)
  const stats = exists && fs.statSync(src)
  const isDirectory = exists && stats.isDirectory()

  if (isDirectory) {
    if (!fs.existsSync(dest)) {
      fs.mkdirSync(dest, { recursive: true })
    }
    fs.readdirSync(src).forEach((childItemName) => {
      copyRecursiveSync(
        path.join(src, childItemName),
        path.join(dest, childItemName)
      )
    })
  } else {
    fs.copyFileSync(src, dest)
  }
}
