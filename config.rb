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
set :build_dir, "build/foobarium"
set :markdown_engine, :redcarpet
set :markdown, fenced_code_blocks: true, smartypants: true

configure :build do
  activate :minify_css
  activate :asset_hash
  activate :relative_assets
end
