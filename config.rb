MARKDOWN_OPTIONS = {
  fenced_code_blocks: true,
  smartypants: true,
  no_intra_emphasis: true,
  autolink: true,
  disable_indented_code_blocks: true
}

class CustomMarkdownRenderer < Redcarpet::Render::HTML
  def initialize(options = {})
    super(options)
  end

  def preprocess(document)
    renderer = Redcarpet::Markdown.new(self, options = MARKDOWN_OPTIONS)
    aside_blocks(document, renderer)
  end

  private

  def aside_blocks(document, renderer)
    document.gsub(/^\[\[aside\n((.|\n)*?)^aside\]\]$/) do |foo|
      "<aside>#{renderer.render($1)}</aside>"
    end
  end
end

helpers do
  require "date"

  def format_date(date)
    Date.parse(date).strftime("%B %-d, %Y")
  end

  def articles
    sitemap.resources.select { |res| res.path.start_with?("article") }
  end
end

set :css_dir, "css"
set :images_dir, "images"
set :markdown_engine, :redcarpet
set :markdown, MARKDOWN_OPTIONS.merge(renderer: CustomMarkdownRenderer)

configure :build do
  activate :minify_css
  activate :asset_hash
  activate :relative_assets
end
