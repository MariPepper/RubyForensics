Gem::Specification.new do |spec|
  spec.name          = "file_integrity_comparator"
  spec.version       = "0.1.0"
  spec.authors       = ["Projeto académico"]
  spec.summary       = "Comparador forense de integridade e diferenças entre ficheiros"
  spec.description   = "Compara hashes SHA-256 e diferenças textuais, incluindo Levenshtein e colunas alteradas."
  spec.files         = Dir["lib/**/*.rb", "bin/*", "README.md", "Gemfile"]
  spec.bindir        = "bin"
  spec.executables   = ["filecompare"]
  spec.require_paths = ["lib"]
end
