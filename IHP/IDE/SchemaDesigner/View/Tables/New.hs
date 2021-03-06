module IHP.IDE.SchemaDesigner.View.Tables.New where

import IHP.ViewPrelude
import IHP.IDE.SchemaDesigner.Types
import IHP.IDE.ToolServer.Types
import IHP.IDE.ToolServer.Layout
import IHP.View.Modal
import IHP.IDE.SchemaDesigner.View.Layout

data NewTableView = NewTableView { statements :: [Statement] }

instance View NewTableView ViewContext where
    beforeRender (context, view) = (context { layout = schemaDesignerLayout }, view)

    html NewTableView { .. } = [hsx|
        <div class="row no-gutters bg-white">
            {renderObjectSelector (zip [0..] statements) Nothing}
        </div>
        {Just modal}
    |]
        where
            modalContent = [hsx|
                <form method="POST" action={CreateTableAction}>

                    <div class="form-group row">
                        <label class="col-sm-2 col-form-label">Name:</label>
                        <div class="col-sm-10">
                            <input name="tableName" type="text" class="form-control" autofocus="autofocus"/>
                            <small class="text-muted">
                                Use the plural form and underscores. E.g.: <code>projects</code>, <code>companies</code>, <code>user_reactions</code>
                            </small>
                        </div>
                    </div>

                    <div class="text-right">
                        <button type="submit" class="btn btn-primary">Create Table</button>
                    </div>
                </form>
            |]
            modalFooter = mempty 
            modalCloseUrl = pathTo TablesAction
            modalTitle = "New Table"
            modal = Modal { modalContent, modalFooter, modalCloseUrl, modalTitle }
