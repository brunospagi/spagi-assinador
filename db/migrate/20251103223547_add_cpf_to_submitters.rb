class AddCpfToSubmitters < ActiveRecord::Migration[8.0]
  def change
    add_column :submitters, :cpf, :string
    add_index :submitters, :cpf
  end
end
