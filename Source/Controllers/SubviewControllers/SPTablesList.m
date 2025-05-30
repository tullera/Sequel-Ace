//
//  SPTablesList.m
//  sequel-pro
//
//  Created by Lorenz Textor (lorenz@textor.ch) on Wed May 1, 2002.
//  Copyright (c) 2002-2003 Lorenz Textor. All rights reserved.
//  Copyright (c) 2012 Sequel Pro Team. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person
//  obtaining a copy of this software and associated documentation
//  files (the "Software"), to deal in the Software without
//  restriction, including without limitation the rights to use,
//  copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
//  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
//  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
//  OTHER DEALINGS IN THE SOFTWARE.
//
//  More info at <https://github.com/sequelpro/sequelpro>

#import "SPTablesList.h"
#import "SPDatabaseDocument.h"
#import "SPTableStructure.h"
#import "SPDatabaseStructure.h"
#import "SPTableContent.h"
#import "SPTableData.h"
#import "SPTableInfo.h"
#import "SPDataImport.h"
#import "SPTableView.h"
#import "ImageAndTextCell.h"
#import "SPTableTextFieldCell.h"
#import "RegexKitLite.h"
#import "SPDatabaseData.h"
#import "SPNavigatorController.h"
#import "SPHistoryController.h"
#import "SPServerSupport.h"
#import "SPAppController.h"
#import "SPSplitView.h"
#import "SPThreadAdditions.h"
#import "SPFunctions.h"
#import "SPCharsetCollationHelper.h"
#import "SPConstants.h"
#import "SPFunctions.h"

#import "sequel-ace-Swift.h"

#import <SPMySQL/SPMySQL.h>

// New table
static NSString *SPNewTableName         = @"SPNewTableName";
static NSString *SPNewTableType         = @"SPNewTableType";
static NSString *SPNewTableCharacterSet = @"SPNewTableCharacterSet";
static NSString *SPNewTableCollation    = @"SPNewTableCollation";

@interface SPTablesList () <NSSplitViewDelegate, NSTableViewDataSource>

- (void)_removeTable:(BOOL)force;
- (void)_truncateTable;
- (void)_addTable;
- (void)_addTableWithDetails:(NSDictionary *)tableDetails;
- (void)_copyTable;
- (void)_renameTableOfType:(SPTableType)tableType from:(NSString *)oldTableName to:(NSString *)newTableName;
- (NSMutableArray *)_allSchemaObjectsOfType:(SPTableType)type;
- (BOOL)_databaseHasObjectOfType:(SPTableType)type;

@property (readwrite, strong) SQLitePinnedTableManager *_SQLitePinnedTableManager ;

@end

@implementation SPTablesList

#pragma mark -
#pragma mark Initialisation

@synthesize _SQLitePinnedTableManager;

- (instancetype)init
{
	if ((self = [super init])) {

		tables = [[NSMutableArray alloc] init];
		filteredTables = tables;
		tableTypes = [[NSMutableArray alloc] init];
		tableComments = [[NSMutableDictionary alloc] init];
		pinnedTables = [[NSMutableArray alloc] init];
		filteredTableTypes = tableTypes;
		isTableListFiltered = NO;
		tableListIsSelectable = YES;
		tableListContainsViews = NO;
		selectedTableType = SPTableTypeNone;
		selectedTableName = nil;
        pinnedTableNotificationName = nil;
		
		prefs = [NSUserDefaults standardUserDefaults];

		[tables addObject:NSLocalizedString(@"TABLES", @"header for table list")];

		addTableCharsetHelper = nil; //initialized in awakeFromNib
		_SQLitePinnedTableManager = SQLitePinnedTableManager.sharedInstance;
	}
	
	return self;
}

- (void)awakeFromNib
{
    [super awakeFromNib];
    
	// Configure the table information pane
	[tableListSplitView setCollapsibleSubviewIndex:1];

    // Collapse the pane if the last state was collapsed
    // after a delay - to fix #719
    if(user_defaults_get_bool_ud(SPTableInformationPanelCollapsed, prefs) == YES){
        executeOnMainThreadAfterADelay(^{
            [self->tableListSplitView setCollapsibleSubviewCollapsed:YES animate:NO];
        }, 3);
    }

	// Configure the table list filter, starting it collapsed
	[tableListFilterSplitView setCollapsibleSubviewIndex:0];
	[tableListFilterSplitView setCollapsibleSubviewCollapsed:YES animate:NO];
	
	// Disable tab edit behaviour in the tables list
	[tablesListView setTabEditingDisabled:YES];

	[prefs addObserver:self forKeyPath:SPGlobalFontSettings options:NSKeyValueObservingOptionNew context:nil];
	
	// Add observers for document task activity
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(startDocumentTaskForTab:)
												 name:SPDocumentTaskStartNotification
											   object:tableDocumentInstance];

	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(endDocumentTaskForTab:)
												 name:SPDocumentTaskEndNotification
											   object:tableDocumentInstance];
	
	[tablesListView registerForDraggedTypes:@[SPNavigatorTableDataPasteboardDragType]];

	//create the charset helper
	addTableCharsetHelper = [[SPCharsetCollationHelper alloc] initWithCharsetButton:tableEncodingButton CollationButton:tableCollationButton];

	NSFont *tableFont = [NSUserDefaults getFont];
	[tablesListView setRowHeight:4.0f + NSSizeToCGSize([@"{ǞṶḹÜ∑zgyf" sizeWithAttributes:@{NSFontAttributeName : tableFont}]).height];

	for (NSTableColumn *column in [tablesListView tableColumns]) {
		[[column dataCell] setFont:tableFont];
	}
}

#pragma mark -
#pragma mark KVO methods

/**
 * This method is called as part of Key Value Observing which is used to watch for prefernce changes which effect the interface.
 */
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	// Table font preference changed
	if ([keyPath isEqualToString:SPGlobalFontSettings]) {
		NSFont *tableFont = [NSUserDefaults getFont];
		[tablesListView setRowHeight:4.0f + NSSizeToCGSize([@"{ǞṶḹÜ∑zgyf" sizeWithAttributes:@{NSFontAttributeName : tableFont}]).height];
		[tablesListView setFont:tableFont];
		[tablesListView reloadData];
		// Force a visual refresh of the table list
		[tablesListView setNeedsDisplay:YES];
		[tablesListView displayIfNeeded];
	}
	else {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

#pragma mark -
#pragma mark IBAction methods

/**
 * Loads all table names in array tables and reload the tableView
 */
- (IBAction)updateTables:(nullable id)sender
{

    SPLog(@"updateTables, sender: %@", sender);

	SPMySQLResult *theResult;
	NSString *previousSelectedTable = nil;
	NSString *previousFilterString = nil;
	BOOL previousTableListIsSelectable = tableListIsSelectable;
	BOOL changeEncoding = ![[mySQLConnection encoding] hasPrefix:@"utf8"];

	if (selectedTableName) previousSelectedTable = [[NSString alloc] initWithString:selectedTableName];

	if (isTableListFiltered) {
		previousFilterString = [[NSString alloc] initWithString:[listFilterField stringValue]];
		filteredTables = tables;
		filteredTableTypes = tableTypes;
		isTableListFiltered = NO;
		[[self onMainThread] clearFilter];
	}
	tableListContainsViews = NO;
	tableListIsSelectable = YES;
	[self deselectAllTables];

	tableListIsSelectable = previousTableListIsSelectable;
	SPMainQSync(^{
		//this has to be executed en-block on the main queue, otherwise the table view might have a chance to access released memory before we tell it to throw away everything.
		[self->tables removeAllObjects];
		[self->tableTypes removeAllObjects];
		[self->tablesListView reloadData];
		// Force a visual refresh of the table list
		[self->tablesListView setNeedsDisplay:YES];
		[self->tablesListView displayIfNeeded];
	});

	if ([tableDocumentInstance database]) {

		// Notify listeners that a query has started
		[[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:@"SMySQLQueryWillBePerformed" object:tableDocumentInstance];

		// Use UTF8 for identifier-based queries
		if (changeEncoding) {
			[mySQLConnection storeEncodingForRestoration];
			[mySQLConnection setEncoding:@"utf8mb4"];
		}

		// Select the table list for the current database.  On MySQL versions after 5 this will include
		// views; on MySQL versions >= 5.0.02 select the "full" list to also select the table type column.
		if ([prefs boolForKey:SPDisplayCommentsInTablesList]) {
			theResult = [mySQLConnection queryString:@"SHOW TABLE STATUS"];
		} else {
			theResult = [mySQLConnection queryString:@"SHOW FULL TABLES"];
		}
		[theResult setDefaultRowReturnType:SPMySQLResultRowAsDictionary];
		[theResult setReturnDataAsStrings:YES]; // TODO: workaround for bug #2700 (#2699)
		if ([theResult numberOfFields] == 1 && [[theResult getRow] isKindOfClass:[NSArray class]]) {
			for (NSArray *eachRow in theResult) {
				[tables addObject:[eachRow objectAtIndex:0]];
				[tableTypes addObject:[NSNumber numberWithInteger:SPTableTypeTable]];
			}
		} else {
			for (NSDictionary *eachRow in theResult) {

				NSMutableDictionary *mutableRow = [eachRow mutableCopy];
				NSString *tableType = [mutableRow objectForKey:@"Table_type"];
				[mutableRow removeObjectForKey:@"Table_type"];

				// Due to encoding problems it can be the case that [resultRow objectAtIndex:0]
				// return NSNull, thus catch that case for safety reasons
				id tableName = [mutableRow objectForKey:@"Name"];
				if (tableName == nil || [tableName isNSNull]) {
					tableName = [mutableRow objectForKey:@"NAME"];
				}
				if ((tableName == nil || [tableName isNSNull]) && mutableRow.allValues.count == 1) {
					tableName = [mutableRow.allValues firstObject];
				}
				if (tableName == nil || [tableName isNSNull]) {
					tableName = @"...";
				}
				[tables addObject:tableName];
				
				// comments is usefull
				id tableComment = [mutableRow objectForKey:@"Comment"];
				if (tableComment == nil || [tableComment isNSNull]) {
					tableComment = [mutableRow objectForKey:@"COMMENT"];
				}
				if (tableComment == nil || [tableComment isNSNull]) {
					tableComment = @"";
				}
				[tableComments setValue:tableComment forKey:tableName];

				if ([@"VIEW" isEqualToString:tableComment] || [@"VIEW" isEqualToString:tableType]) {
					[tableTypes addObject:[NSNumber numberWithInteger:SPTableTypeView]];
					tableListContainsViews = YES;
				} else {
					[tableTypes addObject:[NSNumber numberWithInteger:SPTableTypeTable]];
				}
			}
		}

		/* Grab the procedures and functions
		 *
		 * Using information_schema gives us more info (for information window perhaps?) but breaks
		 * backward compatibility with pre 4 I believe. I left the other methods below, in case.
		 */
        NSString *pQuery = [NSString stringWithFormat:@"SELECT * FROM information_schema.routines WHERE routine_schema = %@ ORDER BY routine_name", [[tableDocumentInstance database] tickQuotedString]];
        theResult = [mySQLConnection queryString:pQuery];
        [theResult setDefaultRowReturnType:SPMySQLResultRowAsArray];
        [theResult setReturnDataAsStrings:YES]; //see tables above
        
        // Check for mysql errors - if information_schema is not accessible for some reasons
        // omit adding procedures and functions
        if(![mySQLConnection queryErrored] && theResult != nil && [theResult numberOfRows] && [theResult numberOfFields] > 3) {

            // Add the header row
            [tables addObject:NSLocalizedString(@"PROCS & FUNCS",@"header for procs & funcs list")];
            [tableTypes addObject:[NSNumber numberWithInteger:SPTableTypeNone]];

            for (NSArray *eachRow in theResult) {
                [tables addObject:[eachRow safeObjectAtIndex:3]];
                if([[eachRow safeObjectAtIndex:4] isNSNull] == NO ){
                    if ([[eachRow safeObjectAtIndex:4] isEqualToString:@"PROCEDURE"]) {
                        [tableTypes addObject:[NSNumber numberWithInteger:SPTableTypeProc]];
                    } else {
                        [tableTypes addObject:[NSNumber numberWithInteger:SPTableTypeFunc]];
                    }
                }
            }
        }

		// Restore encoding if appropriate
		if (changeEncoding) [mySQLConnection restoreStoredEncoding];

		// Notify listeners that the query has finished
		[[NSNotificationCenter defaultCenter] postNotificationOnMainThreadWithName:@"SMySQLQueryHasBeenPerformed" object:tableDocumentInstance];
	}

	// Add the table headers even if no tables were found
	if (tableListContainsViews) {
		[tables insertObject:NSLocalizedString(@"TABLES & VIEWS",@"header for table & views list") atIndex:0];
	} 
	else {
		[tables insertObject:NSLocalizedString(@"TABLES",@"header for table list") atIndex:0];
	}
	
	[tableTypes insertObject:[NSNumber numberWithInteger:SPTableTypeNone] atIndex:0];

	[[tablesListView onMainThread] reloadData];

	// if the previous selected table still exists, select it
	// but not if the update was called from SPTableData since it calls that method
	// if a selected table doesn't exist - this happens if a table was deleted/renamed by an other user
	// or if the table name contains characters which are not supported by the current set encoding
	if ( ![sender isKindOfClass:[SPTableData class]] && previousSelectedTable != nil && [tables indexOfObject:previousSelectedTable] < [tables count]) {
		NSInteger itemToReselect = [tables indexOfObject:previousSelectedTable];
		tableListIsSelectable = YES;
		[[tablesListView onMainThread] selectRowIndexes:[NSIndexSet indexSetWithIndex:itemToReselect] byExtendingSelection:NO];
		tableListIsSelectable = previousTableListIsSelectable;
		selectedTableName = [[NSString alloc] initWithString:[tables objectAtIndex:itemToReselect]];
		selectedTableType = (SPTableType)[[tableTypes objectAtIndex:itemToReselect] integerValue];
	}
    else if (selectedTableName != nil) {
        selectedTableName = nil;
        [[tablesListView onMainThread] selectRowIndexes:[NSIndexSet init] byExtendingSelection:NO];
        selectedTableType = SPTableTypeNone;
    }
    
    [self refreshPinnedTables];

	// Determine whether or not to preserve the existing filter, and whether to
	// show or hide the list filter based on the number of tables
	if ([tables count] > 20) {
		[self showFilter];
		if (previousFilterString) {
			[[listFilterField onMainThread] setStringValue:previousFilterString];
			[[self onMainThread] updateFilter:self];
		}
	} else {
		[self hideFilter];
	}

	// Set the filter placeholder text
	if ([tableDocumentInstance database]) {
		SPMainQSync(^{
			// -cell is a UI call according to Xcode 9.2 (and -setPlaceholderString: is too, obviously)
			[[self->listFilterField cell] setPlaceholderString:NSLocalizedString(@"Filter", @"filter label")];
		});
	}

	if (previousSelectedTable) previousSelectedTable = nil;
	if (previousFilterString) previousFilterString = nil;
	
	// Query the structure of all databases in the background
	if (sender == self)
		// Invoked by SP
		[[tableDocumentInstance databaseStructureRetrieval] queryDbStructureInBackgroundWithUserInfo:nil];
	else
		// User press refresh button ergo force update
		[[tableDocumentInstance databaseStructureRetrieval] queryDbStructureInBackgroundWithUserInfo:@{@"forceUpdate" : @YES, @"cancelQuerying" : @YES}];
    
    [self subscribeToTablePinningNotifications];

}

/**
 * Adds a new table to the tables-array (no changes in mysql-db)
 */
- (IBAction)addTable:(id)sender
{
	if ((![tableSourceInstance saveRowOnDeselect]) || (![tableContentInstance saveRowOnDeselect]) || (![tableDocumentInstance database])) return;

	[[tableDocumentInstance parentWindowControllerWindow] endEditingFor:nil];

	// Populate the table type (engine) popup button
	[tableTypeButton removeAllItems];

	NSArray *engines = [databaseDataInstance getDatabaseStorageEngines];

	// Add default menu item
	[tableTypeButton addItemWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Default (%@)", @"New Table Sheet : Table Engine Dropdown : Default"), [databaseDataInstance getDatabaseDefaultStorageEngine]]];
	[[tableTypeButton menu] addItem:[NSMenuItem separatorItem]];

	for (NSDictionary *engine in engines)
	{
		[tableTypeButton safeAddItemWithTitle:[engine safeObjectForKey:@"Engine"]];
	}

	// Setup the charset and collation dropdowns
	[addTableCharsetHelper setDatabaseData:databaseDataInstance];
	[addTableCharsetHelper setServerSupport:[tableDocumentInstance serverSupport]];
	[addTableCharsetHelper setPromoteUTF8:YES];
	[addTableCharsetHelper setDefaultCharsetFormatString:NSLocalizedString(@"Inherit from database (%@)", @"New Table Sheet : Table Encoding Dropdown : Default inherited from database")];
	[addTableCharsetHelper setDefaultCollationFormatString:NSLocalizedString(@"Inherit from database (%@)", @"New Table Sheet : Table Collation Dropdown : Default inherited from database")];
	[addTableCharsetHelper setDefaultCharset:[databaseDataInstance getDatabaseDefaultCharacterSet]];
	[addTableCharsetHelper setDefaultCollation:[databaseDataInstance getDatabaseDefaultCollation]];
	[addTableCharsetHelper setSelectedCharset:nil]; //reset to not carry over state from last time sheet was shown
	[addTableCharsetHelper setSelectedCollation:nil];
	[addTableCharsetHelper setEnabled:YES];
	
	// Set the focus to the name field
	[tableSheet makeFirstResponder:tableNameField];

	[[tableDocumentInstance parentWindowControllerWindow] beginSheet:tableSheet completionHandler:^(NSModalResponse returnCode) {
		[self->addTableCharsetHelper setEnabled:NO];
		if (returnCode == NSModalResponseOK) {
			[self _addTable];
		}
	}];
}

- (IBAction)tableEncodingButtonChanged:(id)sender
{
	NSString *fmtStrDefaultId      = NSLocalizedString(@"Default (%@)",@"Add Table : Collation : Default ($1 = collation name)");
	NSString *fmtStrDefaultUnknown = NSLocalizedString(@"Default",@"Add Table Sheet : Collation : Default (unknown)"); // MySQL < 4.1.0
	
	//throw out all items
	[tableCollationButton removeAllItems];
	//we'll enable that later if the user can actually change the selection.
	[tableCollationButton setEnabled:NO];
	
	/* logic below is as follows:
	 *   if the database default charset is selected also use the database default collation
	 *   regardless of default charset or not get the list of all collations that apply
	 *   if a non-default charset is selected look out for it's default collation and promote that to the top as default
	 *
	 * Selecting a default charset (or collation) means that we don't want to specify one in the CREATE TABLE statement.
	 */
	
	//is the default charset currently selected?
	BOOL isDefaultCharset = ([tableEncodingButton indexOfSelectedItem] == 0);
	
	if(isDefaultCharset) {
		NSString *defaultCollation = [databaseDataInstance getDatabaseDefaultCollation];
		NSString *defaultItemTitle = (defaultCollation)? [NSString stringWithFormat:fmtStrDefaultId,defaultCollation] : fmtStrDefaultUnknown;
		[tableCollationButton safeAddItemWithTitle:defaultItemTitle];
		//add the separator for the real items
		[[tableCollationButton menu] addItem:[NSMenuItem separatorItem]];
	}
	
	//get the charset id the lazy way
	NSString *charsetName = [[tableEncodingButton title] stringByMatching:@"\\((.*)\\)\\Z" capture:1L];
	//this should not fail as even default is "Default (charset)" - if it does there's nothing we can do
	if(!charsetName) {
		NSLog(@"%s: Can't find charset id in encoding name <%@>. Format should be <Description (id)>.",__func__,[tableEncodingButton title]);
		return;
	}
	//now let's get the list of collations for the selected charset id
	NSArray *applicableCollations = [databaseDataInstance getDatabaseCollationsForEncoding:charsetName];
	
	//got something?
	if (![applicableCollations count])
		return;
	
	//add the real items
	for (NSDictionary *collation in applicableCollations) 
	{
		NSString *collationName = [collation safeObjectForKey:@"COLLATION_NAME"];
		[tableCollationButton safeAddItemWithTitle:collationName];
		
		//if this is not the server default charset let's find it's default collation too
		if(!isDefaultCharset && [[collation objectForKey:@"IS_DEFAULT"] isEqualToString:@"Yes"]) {
			NSString *defaultCollateTitle = [NSString stringWithFormat:fmtStrDefaultId,collationName];
			//add it to the top of the list
			[tableCollationButton insertItemWithTitle:defaultCollateTitle atIndex:0];
			//add a separator underneath
			[[tableCollationButton menu] insertItem:[NSMenuItem separatorItem] atIndex:1];
		}
	}
	//reset selection to first item (it may moved when adding the default item)
	[tableCollationButton selectItemAtIndex:0];
	//yay, now there is actually something not the Default item, so we can enable the button
	[tableCollationButton setEnabled:YES];
}

/**
 * Closes the current sheet and stops the modal session
 */
- (IBAction)closeSheet:(id)sender
{
	[NSApp endSheet:[sender window] returnCode:[sender tag]];
	[[sender window] orderOut:self];
}

/**
 * Invoked when user hits the remove button alert sheet to ask user if he really wants to delete the table.
 */
- (IBAction)removeTable:(id)sender {
	if (![tablesListView numberOfSelectedRows]) {
		return;
	}

	[[tableDocumentInstance parentWindowControllerWindow] endEditingFor:nil];

	NSString *alertTitle = @"";
	NSString *alertInformativeText = @"";

	NSIndexSet *indexes = [tablesListView selectedRowIndexes];

	NSString *tblTypes = @"";
	NSUInteger currentIndex = [indexes lastIndex];

	if ([tablesListView numberOfSelectedRows] == 1) {
		if ([[filteredTableTypes objectAtIndex:currentIndex] integerValue] == SPTableTypeView) {
			tblTypes = NSLocalizedString(@"view", @"view");
		} else if ([[filteredTableTypes objectAtIndex:currentIndex] integerValue] == SPTableTypeTable) {
			tblTypes = NSLocalizedString(@"table", @"table");
		} else if ([[filteredTableTypes objectAtIndex:currentIndex] integerValue] == SPTableTypeProc) {
			tblTypes = NSLocalizedString(@"procedure", @"procedure");
		} else if ([[filteredTableTypes objectAtIndex:currentIndex] integerValue] == SPTableTypeFunc) {
			tblTypes = NSLocalizedString(@"function", @"function");
		}

		alertTitle = [NSString stringWithFormat:NSLocalizedString(@"Delete %@ '%@'?", @"delete table/view message"), tblTypes, [filteredTables objectAtIndex:[tablesListView selectedRow]]];
		alertInformativeText = [NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete the %@ '%@'? This operation cannot be undone.", @"delete table/view informative message"), tblTypes, [filteredTables objectAtIndex:[tablesListView selectedRow]]];
	} else {
		BOOL areTableTypeEqual = YES;
		NSInteger lastType = [[filteredTableTypes objectAtIndex:currentIndex] integerValue];
		
		while (currentIndex != NSNotFound) {
			if ([[filteredTableTypes objectAtIndex:currentIndex] integerValue] != lastType) {
				areTableTypeEqual = NO;
				break;
			}
			
			currentIndex = [indexes indexLessThanIndex:currentIndex];
		}
		
		if (areTableTypeEqual) {
			switch (lastType) {
				case SPTableTypeTable:
					tblTypes = NSLocalizedString(@"tables", @"tables");
					break;
				case SPTableTypeView:
					tblTypes = NSLocalizedString(@"views", @"views");
					break;
				case SPTableTypeProc:
					tblTypes = NSLocalizedString(@"procedures", @"procedures");
					break;
				case SPTableTypeFunc:
					tblTypes = NSLocalizedString(@"functions", @"functions");
					break;
			}

		} else {
			tblTypes = NSLocalizedString(@"items", @"items");
		}

		alertTitle = [NSString stringWithFormat:NSLocalizedString(@"Delete selected %@?", @"delete tables/views message"), tblTypes];
		alertInformativeText = [NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete the selected %@? This operation cannot be undone.", @"delete tables/views informative message"), tblTypes];
	}
	NSAlert *alert = [[NSAlert alloc] init];
	[alert setMessageText:alertTitle];
	[alert setInformativeText:alertInformativeText];

	// Order of buttons matters! first button has "firstButtonReturn" return value from runModal()
	[alert addButtonWithTitle:NSLocalizedString(@"Delete", @"delete button")];
	[alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"cancel button")];
	[alert setAlertStyle:NSAlertStyleCritical];

	[alert.suppressionButton setTitle:NSLocalizedString(@"Force delete (disables integrity checks)", @"force table deletion button text")];
	[alert.suppressionButton setToolTip:NSLocalizedString(@"Disables foreign key checks (FOREIGN_KEY_CHECKS) before deletion and re-enables them afterwards.", @"force table deltion button text tooltip")];
	[alert setShowsSuppressionButton:YES];

	NSInteger alertReturnCode = [alert runModal];
	if (alertReturnCode == NSAlertFirstButtonReturn) {
		[self _removeTable:[[alert suppressionButton] state] == NSControlStateValueOn];
	}
}

/**
 * Copies a table/view/proc/func, if desired with content
 */
- (IBAction)copyTable:(id)sender
{
	if ([tablesListView numberOfSelectedRows] != 1) return;
	if (![tableSourceInstance saveRowOnDeselect] || ![tableContentInstance saveRowOnDeselect]) return;

	[[self onMainThread] setDatabases];

	[[tableDocumentInstance parentWindowControllerWindow] endEditingFor:nil];

	NSInteger objectType = [[filteredTableTypes objectAtIndex:[tablesListView selectedRow]] integerValue];

	[copyTableContentSwitch setState:NSControlStateValueOff];
	[copyTableContentSwitch setEnabled:objectType == SPTableTypeTable];

	NSString *tableType = @"";

	switch (objectType)
	{
		case SPTableTypeTable:
			tableType = NSLocalizedString(@"table", @"table");
			[copyTableContentSwitch setState:[[prefs objectForKey:SPCopyContentOnTableCopy] boolValue]];
			break;
		case SPTableTypeView:
			tableType = NSLocalizedString(@"view", @"view");
			break;
		case SPTableTypeProc:
			tableType = NSLocalizedString(@"procedure", @"procedure");
			break;
		case SPTableTypeFunc:
			tableType = NSLocalizedString(@"function", @"function");
			break;
	}

    // from docs:
    // A window that uses NSWindowStyleMaskBorderless can't become key or main
    // meaning it can't take input, so switch the style here.
    // It doesn't change how the popup looks.
    copyTableSheet.styleMask = NSWindowStyleMaskTitled;

	[copyTableMessageField setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Duplicate %@ '%@' to:", @"duplicate object message"), tableType, [self tableName]]];
	[copyTableNameField setStringValue:[NSString stringWithFormat:@"%@_copy", [filteredTables objectAtIndex:[tablesListView selectedRow]]]];

	[copyTableButton setEnabled:[self isTableNameValid:[copyTableNameField stringValue] forType:[self tableType]]];

	[[tableDocumentInstance parentWindowControllerWindow] beginSheet:copyTableSheet completionHandler:^(NSModalResponse returnCode) {
		if (returnCode == NSModalResponseOK) {
			[self _copyTable];
		}
	}];
}


- (void)setDatabases {
    if (!chooseDatabaseButton) {
        return;
    }

	[chooseDatabaseButton removeAllItems];

	[chooseDatabaseButton addItemWithTitle:NSLocalizedString(@"Choose Database...", @"menu item for choose db")];
	[[chooseDatabaseButton menu] addItem:[NSMenuItem separatorItem]];
	[[chooseDatabaseButton menu] addItemWithTitle:NSLocalizedString(@"Refresh Databases", @"menu item to refresh databases") action:@selector(setDatabases:) keyEquivalent:@""];
	[[chooseDatabaseButton menu] addItem:[NSMenuItem separatorItem]];

	NSArray *theDatabaseList = [mySQLConnection databases];

	NSMutableArray *allDatabases = [[NSMutableArray alloc] initWithCapacity:[theDatabaseList count]];

	for (NSString *databaseName in theDatabaseList)
	{
		[allDatabases addObject:databaseName];
	}

	// Add user databases
	for (NSString *database in allDatabases)
	{
		[chooseDatabaseButton safeAddItemWithTitle:database];
	}

	[chooseDatabaseButton itemAtIndex:1].enabled = YES;

	(![mySQLConnection database]) ? [chooseDatabaseButton selectItemAtIndex:0] : [chooseDatabaseButton selectItemWithTitle:[mySQLConnection database]];
}
/**
 * This action starts editing the table name in the table list
 */
- (IBAction)renameTable:(id)sender
{
	if ((![tableSourceInstance saveRowOnDeselect]) || (![tableContentInstance saveRowOnDeselect]) || (![tableDocumentInstance database])) {
		return;
	}

	[[tableDocumentInstance parentWindowControllerWindow] endEditingFor:nil];

    if ([tablesListView numberOfSelectedRows] != 1) return;
    if (![[self tableName] length]) return;

    [tablesListView editColumn:0 row:[tablesListView selectedRow] withEvent:nil select:YES];
}

/**
 * Truncates the currently selected table(s).
 */
- (IBAction)truncateTable:(id)sender {
	if (![tablesListView numberOfSelectedRows]) {
		return;
	}

	[[tableDocumentInstance parentWindowControllerWindow] endEditingFor:nil];

	NSString *alertTitle = @"";
	NSString *alertInformativeText = @"";
	if ([tablesListView numberOfSelectedRows] == 1) {
		alertTitle = [NSString stringWithFormat:NSLocalizedString(@"Truncate table '%@'?", @"truncate table message"), [filteredTables objectAtIndex:[tablesListView selectedRow]]];
		alertInformativeText = [NSString stringWithFormat:NSLocalizedString(@"Are you sure you want to delete ALL records in the table '%@'? This operation cannot be undone.", @"truncate table informative message"), [filteredTables objectAtIndex:[tablesListView selectedRow]]];
	}
	else {
		alertTitle = NSLocalizedString(@"Truncate selected tables?", @"truncate tables message");
		alertInformativeText = NSLocalizedString(@"Are you sure you want to delete ALL records in the selected tables? This operation cannot be undone.", @"truncate tables informative message");
	}

	[NSAlert createDefaultAlertWithTitle:alertTitle message:alertInformativeText primaryButtonTitle:NSLocalizedString(@"Truncate", @"truncate button") primaryButtonHandler:^{
		[self _truncateTable];
	} cancelButtonHandler:nil];
}

- (IBAction)togglePinTable:(nullable id)sender {
  NSIndexSet *indexes = [tablesListView selectedRowIndexes];
  SPLog(@"togglePinTable");
  
  if (!selectedTableName && !indexes) {
    SPLog(@"no table selected");
		return;
	}
  
  NSString *databaseName = [mySQLConnection database];
  NSString *hostName = [mySQLConnection host];
  
  NSMutableArray *selectedTables = [NSMutableArray array];
  BOOL isPinned = NO;
  
  if (selectedTableName) {
    [selectedTables addObject:selectedTableName];
    isPinned = [pinnedTables containsObject:selectedTableName];
  } else {
    selectedTables = [NSMutableArray arrayWithArray:[filteredTables objectsAtIndexes:indexes]];
    isPinned = [[sender title] isEqualToString:@"Unpin Tables"];
  }
  
  for (NSString *tableName in selectedTables) {
    if (isPinned) { // unpin selection
      [_SQLitePinnedTableManager unpinTableWithHostName:hostName databaseName:databaseName tableToUnpin:tableName];
    } else { // pin selection
      [_SQLitePinnedTableManager pinTableWithHostName:hostName databaseName:databaseName tableToPin:tableName];
    }
  }
  
  [tablesListView deselectAll:self];
  [[NSNotificationCenter defaultCenter] postNotificationName:pinnedTableNotificationName object:nil];
  // actual pin toggle will happen when notification is received and processed
}


- (IBAction)copyTableName:(nullable id)sender {
    if (!selectedTableName) {
        return;
    }

    NSString *databaseName = [mySQLConnection database];

    NSString *copiedSyntax =[NSString stringWithFormat:@"%@.%@", databaseName, selectedTableName];
    if ([copiedSyntax length] > 0) {
        // Copy to the clipboard
        NSPasteboard *pb = [NSPasteboard generalPasteboard];

        [pb declareTypes:@[NSPasteboardTypeString] owner:self];
        [pb setString:copiedSyntax forType:NSPasteboardTypeString];

    }
}
/**
 * Open the table in a new tab.
 */
- (IBAction)openTableInNewTab:(id)sender {
    // Get the current state
    NSDictionary *allStateDetails = @{
        @"connection" : @YES,
        @"history"    : @YES,
        @"session"    : @YES,
        @"query"      : @YES,
        @"password"   : @YES
    };
    NSMutableDictionary *documentState = [NSMutableDictionary dictionaryWithDictionary:[tableDocumentInstance stateIncludingDetails:allStateDetails]];

    // Ensure it's set to autoconnect, and clear the table
    [documentState setObject:@YES forKey:@"auto_connect"];

    [[NSNotificationCenter defaultCenter] postNotificationName:SPDocumentDuplicateTabNotification object:nil userInfo:documentState];
}

- (IBAction)openTableInNewWindow:(id)sender {
	// Create new window
	[SPAppDelegate newWindow:self];

    NSDictionary *allStateDetails = @{
        @"connection" : @YES,
        @"history"    : @YES,
        @"session"    : @YES,
        @"query"      : @YES,
        @"password"   : @YES
    };
    NSMutableDictionary *documentState = [NSMutableDictionary dictionaryWithDictionary:[tableDocumentInstance stateIncludingDetails:allStateDetails]];

    // Ensure it's set to autoconnect, and clear the table
    [documentState setObject:@YES forKey:@"auto_connect"];

    // Set the connection on the new tab
    [[SPAppDelegate frontDocument] setState:documentState];
}

/**
 * Toggle whether the splitview is collapsed.
 */
- (IBAction)togglePaneCollapse:(id)sender
{
	[tableListSplitView toggleCollapse:sender];

	[prefs setObject:[NSNumber numberWithBool:[tableListSplitView isCollapsibleSubviewCollapsed]] forKey:SPTableInformationPanelCollapsed];
}

#pragma mark -
#pragma mark Additional methods

/**
 * Sets the connection (received from SPDatabaseDocument) and makes things that have to be done only once
 */
- (void)setConnection:(SPMySQLConnection *)theConnection
{
	mySQLConnection = theConnection;
	
	[self updateTables:self];
}

/**
 * Performs interface validation for various controls.
 */
- (void)controlTextDidChange:(NSNotification *)notification
{
	id object = [notification object];

	if (object == tableNameField) {
		[addTableButton setEnabled:[self isTableNameValid:[tableNameField stringValue] forType: SPTableTypeTable]];
	}

	else if (object == copyTableNameField) {
		[copyTableButton setEnabled:[self isTableNameValid:[copyTableNameField stringValue] forType:[self tableType]]];
	}
}

/**
 * Controls the NSTextField's press RETURN event of Add/Rename/Duplicate sheets
 */
- (void)controlTextDidEndEditing:(NSNotification *)notification
{
	id object = [notification object];

	// Only RETURN/ENTER will be recognized for Add/Rename/Duplicate sheets to
	// activate the Add/Rename/Duplicate buttons
	if([[[notification userInfo] objectForKey:@"NSTextMovement"] integerValue] != 0)
		return;

	if (object == tableNameField) {
		[addTableButton performClick:object];
	}
	else if (object == copyTableNameField) {
		[copyTableButton performClick:object];
	}
}

/**
 * Updates application state to match the current selection, including
 * updating the interface selection if appropriate.
 * Takes a dictionary of selection details, containing the selection name
 * and type, and updates stored variables and the table list interface to
 * match.
 * Should be called on the main thread.
 */
- (void)setSelectionState:(NSDictionary *)selectionDetails
{
	// First handle empty or multiple selections
	if (!selectionDetails || ![selectionDetails objectForKey:@"name"]) {
		NSIndexSet *indexes = [tablesListView selectedRowIndexes];
		// Update the selected table name and type
		
		if (selectedTableName) selectedTableName = nil;

    [pinTableContextMenuItem setHidden:YES];
    [pinTableMenuItem setHidden:YES];
		
		// Set gear menu items Remove/Duplicate table/view according to the table types
		// if at least one item is selected
		if ([indexes count]) {

			NSUInteger currentIndex = [indexes lastIndex];
			BOOL areTableTypeEqual = YES;
			NSInteger lastType = [[filteredTableTypes objectAtIndex:currentIndex] integerValue];
      
      
      // If every selected table is pinned, show the "Unpin Tables" menu item
      // If at least one selected table is not pinned, show the "Pin Tables" menu item
      BOOL isGroupPinned = YES;
      for (NSUInteger index = [indexes firstIndex]; index != NSNotFound; index = [indexes indexGreaterThanIndex:index]) {
        if (![pinnedTables containsObject:[filteredTables objectAtIndex:index]]) {
          SPLog(@"Found table %@ isn't pinned", [filteredTables objectAtIndex:index]);
          isGroupPinned = NO;
          break;
        }
      }

			while (currentIndex != NSNotFound)
			{
				if ([[filteredTableTypes objectAtIndex:currentIndex] integerValue] != lastType) {
					areTableTypeEqual = NO;
					break;
				}

				currentIndex = [indexes indexLessThanIndex:currentIndex];
			}

			if (areTableTypeEqual) {
				switch (lastType) 
				{
					case SPTableTypeTable:
						[removeTableMenuItem setTitle:NSLocalizedString(@"Delete Tables", @"delete tables menu title")];
						[truncateTableButton setTitle:NSLocalizedString(@"Truncate Tables", @"truncate tables menu item")];
						[removeTableContextMenuItem setTitle:NSLocalizedString(@"Delete Tables", @"delete tables menu title")];
						[truncateTableContextMenuItem setTitle:NSLocalizedString(@"Truncate Tables", @"truncate tables menu item")];
            [pinTableMenuItem setTitle:NSLocalizedString(!isGroupPinned ? @"Pin Tables" : @"Unpin Tables", @"pin tables menu title")];
            [pinTableContextMenuItem setTitle:NSLocalizedString(!isGroupPinned ? @"Pin Tables" : @"Unpin Tables", @"pin tables menu title")];
            [pinTableMenuItem setHidden:NO];
            [pinTableContextMenuItem setHidden:NO];
						[truncateTableButton setHidden:NO];
						[truncateTableContextMenuItem setHidden:NO];
						break;
					case SPTableTypeView:
						[removeTableMenuItem setTitle:NSLocalizedString(@"Delete Views", @"delete views menu title")];
						[removeTableContextMenuItem setTitle:NSLocalizedString(@"Delete Views", @"delete views menu title")];
						[truncateTableButton setHidden:YES];
						[truncateTableContextMenuItem setHidden:YES];
						break;
					case SPTableTypeProc:
						[removeTableMenuItem setTitle:NSLocalizedString(@"Delete Procedures", @"delete procedures menu title")];
						[removeTableContextMenuItem setTitle:NSLocalizedString(@"Delete Procedures", @"delete procedures menu title")];
						[truncateTableButton setHidden:YES];
						[truncateTableContextMenuItem setHidden:YES];
						break;
					case SPTableTypeFunc:
						[removeTableMenuItem setTitle:NSLocalizedString(@"Delete Functions", @"delete functions menu title")];
						[removeTableContextMenuItem setTitle:NSLocalizedString(@"Delete Functions", @"delete functions menu title")];
						[truncateTableButton setHidden:YES];
						[truncateTableContextMenuItem setHidden:YES];
						break;
				}

			} else {
				[removeTableMenuItem setTitle:NSLocalizedString(@"Delete Items", @"delete items menu title")];
				[removeTableContextMenuItem setTitle:NSLocalizedString(@"Delete Items", @"delete items menu title")];
				[truncateTableButton setHidden:YES];
				[truncateTableContextMenuItem setHidden:YES];
			}

		}

		// Context menu
		[renameTableContextMenuItem setHidden:YES];
		[openTableInNewTabContextMenuItem setHidden:YES];
		[openTableInNewWindowContextMenuItem setHidden:YES];
    [copyTableNameContextMenuItem setHidden:YES];
		[separatorTableContextMenuItem3 setHidden:NO];
		[duplicateTableContextMenuItem setHidden:YES];
		[separatorTableContextMenuItem setHidden:YES];
		[separatorTableContextMenuItem2 setHidden:NO];
		[showCreateSyntaxContextMenuItem setTitle:NSLocalizedString(@"Show Create Syntaxes...", @"show create syntaxes menu item")];
		[showCreateSyntaxContextMenuItem setHidden:NO];
		[copyCreateSyntaxContextMenuItem setTitle:NSLocalizedString(@"Copy Create Syntaxes",@"Table List : Context Menu : Copy CREATE syntax (multiple selection)")];
		[copyCreateSyntaxContextMenuItem setHidden:NO];

		// 'Gear' menu
		[renameTableMenuItem setHidden:YES];
		[openTableInNewTabMenuItem setHidden:YES];
		[openTableInNewWindowMenuItem setHidden:YES];
		[separatorTableMenuItem3 setHidden:NO];
		[duplicateTableMenuItem setHidden:YES];
		[separatorTableMenuItem setHidden:YES];
		[separatorTableMenuItem2 setHidden:NO];
		[showCreateSyntaxMenuItem setTitle:NSLocalizedString(@"Show Create Syntaxes...", @"show create syntaxes menu item")];
		[showCreateSyntaxMenuItem setHidden:NO];
		[copyCreateSyntaxMenuItem setTitle:NSLocalizedString(@"Copy Create Syntaxes", @"Table List : Gear Menu : Copy CREATE syntax (multiple selection)")];
		[copyCreateSyntaxMenuItem setHidden:NO];

		// Get main menu "Table"'s submenu
		NSMenu *tableSubMenu = [[[NSApp mainMenu] itemWithTag:SPMainMenuTable] submenu];

		[[tableSubMenu itemAtIndex:4] setTitle:NSLocalizedString(@"Copy Create Syntaxes", @"copy create syntaxes menu item")];
		[[tableSubMenu itemAtIndex:5] setTitle:NSLocalizedString(@"Show Create Syntaxes...", @"show create syntaxes menu item")];

		[[tableSubMenu itemAtIndex:7] setTitle:NSLocalizedString(@"Check Selected Items", @"check selected items menu item")];
		[[tableSubMenu itemAtIndex:8] setTitle:NSLocalizedString(@"Repair Selected Items", @"repair selected items menu item")];

		[[tableSubMenu itemAtIndex:10] setTitle:NSLocalizedString(@"Analyze Selected Items", @"analyze selected items menu item")];
		[[tableSubMenu itemAtIndex:11] setTitle:NSLocalizedString(@"Optimize Selected Items", @"optimize selected items menu item")];

		[[tableSubMenu itemAtIndex:12] setTitle:NSLocalizedString(@"Flush Selected Items", @"flush selected items menu item")];
		[[tableSubMenu itemAtIndex:13] setTitle:NSLocalizedString(@"Checksum Selected Items", @"checksum selected items menu item")];

		[[tableSubMenu itemAtIndex:4] setHidden:NO];
		[[tableSubMenu itemAtIndex:5] setHidden:NO];
		[[tableSubMenu itemAtIndex:6] setHidden:NO];
		[[tableSubMenu itemAtIndex:7] setHidden:NO];
		[[tableSubMenu itemAtIndex:8] setHidden:NO];
		[[tableSubMenu itemAtIndex:9] setHidden:NO];
		[[tableSubMenu itemAtIndex:10] setHidden:NO];
		[[tableSubMenu itemAtIndex:11] setHidden:NO];

		return;
	}

	// If a new selection has been provided, store variables and update the interface to match
	NSString *selectedItemName = [selectionDetails objectForKey:@"name"];
	SPTableType selectedItemType = (SPTableType)[[selectionDetails objectForKey:@"type"] integerValue];

	// Update the selected table name and type
	selectedTableName = [[NSString alloc] initWithString:selectedItemName];
	selectedTableType = selectedItemType;

	// Remove the "current selection" item for filtered lists if appropriate
	if (isTableListFiltered && [tablesListView selectedRow] < (NSInteger)[filteredTables count] - 2 && [filteredTables count] > 2
		&& [[filteredTableTypes objectAtIndex:[filteredTableTypes count]-2] integerValue] == SPTableTypeNone
		&& [[filteredTables objectAtIndex:[filteredTables count]-2] isEqualToString:NSLocalizedString(@"CURRENT SELECTION",@"header for current selection in filtered list")])
	{
		[filteredTables removeObjectsInRange:NSMakeRange([filteredTables count]-2, 2)];
		[filteredTableTypes removeObjectsInRange:NSMakeRange([filteredTableTypes count]-2, 2)];
		[tablesListView reloadData];
	}

	// Show menu separators
	[separatorTableMenuItem setHidden:NO];
	[separatorTableContextMenuItem setHidden:NO];
	[separatorTableMenuItem2 setHidden:NO];
	[separatorTableContextMenuItem2 setHidden:NO];

	// Set gear menu items Remove/Duplicate table/view and mainMenu > Table items
	// according to the table types
	NSMenu *tableSubMenu = [[[NSApp mainMenu] itemWithTag:SPMainMenuTable] submenu];

    BOOL isCurrentSelectionPinned = [pinnedTables containsObject: selectedTableName];

	// Enable/disable the various menu items depending on the selected item. Also update their titles.
	// Note, that this should ideally be moved to menu item validation as opposed to using fixed item positions.
	if (selectedTableType == SPTableTypeView)
	{
		// Change mainMenu > Table > ... according to table type
		[[tableSubMenu itemAtIndex:4] setTitle:NSLocalizedString(@"Copy Create View Syntax", @"copy create view syntax menu item")];
		[[tableSubMenu itemAtIndex:5] setTitle:NSLocalizedString(@"Show Create View Syntax...", @"show create view syntax menu item")];
		[[tableSubMenu itemAtIndex:6] setHidden:NO]; // Divider
		[[tableSubMenu itemAtIndex:7] setHidden:NO];
		[[tableSubMenu itemAtIndex:7] setTitle:NSLocalizedString(@"Check View", @"check view menu item")];
		[[tableSubMenu itemAtIndex:8] setHidden:YES]; // Repair
		[[tableSubMenu itemAtIndex:9] setHidden:YES]; // Divider
		[[tableSubMenu itemAtIndex:10] setHidden:YES]; // Analyse
		[[tableSubMenu itemAtIndex:11] setHidden:YES]; // Optimize
		[[tableSubMenu itemAtIndex:12] setHidden:NO];
		[[tableSubMenu itemAtIndex:12] setTitle:NSLocalizedString(@"Flush View", @"flush view menu item")];
		[[tableSubMenu itemAtIndex:13] setHidden:YES]; // Checksum

		[renameTableMenuItem setHidden:NO]; // we don't have to check the mysql version
		[renameTableMenuItem setTitle:NSLocalizedString(@"Rename View...", @"rename view menu title")];
		[duplicateTableMenuItem setHidden:NO];
		[duplicateTableMenuItem setTitle:NSLocalizedString(@"Duplicate View...", @"duplicate view menu title")];
		[truncateTableButton setHidden:YES];
		[removeTableMenuItem setTitle:NSLocalizedString(@"Delete View", @"delete view menu title")];
		[openTableInNewTabMenuItem setHidden:NO];
		[openTableInNewWindowMenuItem setHidden:NO];
		[separatorTableMenuItem3 setHidden:NO];
		[openTableInNewTabMenuItem setTitle:NSLocalizedString(@"Open View in New Tab", @"open view in new table title")];
		[openTableInNewWindowMenuItem setTitle:NSLocalizedString(@"Open View in New Window", @"Tables List : Gear Menu : Duplicate connection to new window")];
        NSString * pinViewLocalizedString = NSLocalizedString(isCurrentSelectionPinned ? @"Unpin View" : @"Pin View", @"pin view menu item title");
		[pinTableMenuItem setHidden:NO];
        [pinTableMenuItem setTitle:pinViewLocalizedString];
		[showCreateSyntaxMenuItem setHidden:NO];
		[showCreateSyntaxMenuItem setTitle:NSLocalizedString(@"Show Create View Syntax...", @"show create view syntax menu item")];
		[copyCreateSyntaxMenuItem setHidden:NO];
		[copyCreateSyntaxMenuItem setTitle:NSLocalizedString(@"Copy Create View Syntax",@"Table List : Gear Menu : Copy CREATE view statement")];

		[renameTableContextMenuItem setHidden:NO]; // we don't have to check the mysql version
		[renameTableContextMenuItem setTitle:NSLocalizedString(@"Rename View...", @"rename view menu title")];
		[duplicateTableContextMenuItem setHidden:NO];
		[duplicateTableContextMenuItem setTitle:NSLocalizedString(@"Duplicate View...", @"duplicate view menu title")];
		[truncateTableContextMenuItem setHidden:YES];
		[removeTableContextMenuItem setTitle:NSLocalizedString(@"Delete View", @"delete view menu title")];
		[openTableInNewTabContextMenuItem setHidden:NO];
		[openTableInNewWindowContextMenuItem setHidden:NO];
		[separatorTableContextMenuItem3 setHidden:NO];
		[openTableInNewTabContextMenuItem setTitle:NSLocalizedString(@"Open View in New Tab", @"open view in new tab title")];
		[openTableInNewWindowContextMenuItem setTitle:NSLocalizedString(@"Open View in New Window", @"Tables List : Context Menu : Duplicate connection to new window")];
		[pinTableContextMenuItem setHidden:NO];
        [pinTableContextMenuItem setTitle:pinViewLocalizedString];
        [copyTableNameContextMenuItem setHidden:NO];
        [copyTableNameContextMenuItem setTitle:NSLocalizedString(@"Copy Table Name",@"Table List : Context Menu : copy Table's name")];
		[showCreateSyntaxContextMenuItem setHidden:NO];
		[showCreateSyntaxContextMenuItem setTitle:NSLocalizedString(@"Show Create View Syntax...", @"show create view syntax menu item")];
		[copyCreateSyntaxContextMenuItem setHidden:NO];
		[copyCreateSyntaxContextMenuItem setTitle:NSLocalizedString(@"Copy Create View Syntax",@"Table List : Context Menu : Copy CREATE view statement")];
	}
	else if (selectedTableType == SPTableTypeTable) {
		[[tableSubMenu itemAtIndex:4] setTitle:NSLocalizedString(@"Copy Create Table Syntax", @"copy create table syntax menu item")];
		[[tableSubMenu itemAtIndex:5] setTitle:NSLocalizedString(@"Show Create Table Syntax...", @"show create table syntax menu item")];
		[[tableSubMenu itemAtIndex:6] setHidden:NO]; // divider
		[[tableSubMenu itemAtIndex:7] setHidden:NO];
		[[tableSubMenu itemAtIndex:7] setTitle:NSLocalizedString(@"Check Table", @"check table menu item")];
		[[tableSubMenu itemAtIndex:8] setHidden:NO];
		[[tableSubMenu itemAtIndex:8] setTitle:NSLocalizedString(@"Repair Table", @"repair table menu item")];
		[[tableSubMenu itemAtIndex:9] setHidden:NO]; // divider
		[[tableSubMenu itemAtIndex:10] setHidden:NO];
		[[tableSubMenu itemAtIndex:10] setTitle:NSLocalizedString(@"Analyze Table", @"analyze table menu item")];
		[[tableSubMenu itemAtIndex:11] setHidden:NO];
		[[tableSubMenu itemAtIndex:11] setTitle:NSLocalizedString(@"Optimize Table", @"optimize table menu item")];
		[[tableSubMenu itemAtIndex:12] setHidden:NO];
		[[tableSubMenu itemAtIndex:12] setTitle:NSLocalizedString(@"Flush Table", @"flush table menu item")];
		[[tableSubMenu itemAtIndex:13] setHidden:NO];
		[[tableSubMenu itemAtIndex:13] setTitle:NSLocalizedString(@"Checksum Table", @"checksum table menu item")];

		[renameTableMenuItem setHidden:NO];
		[renameTableMenuItem setTitle:NSLocalizedString(@"Rename Table...", @"rename table menu title")];
		[duplicateTableMenuItem setHidden:NO];
		[duplicateTableMenuItem setTitle:NSLocalizedString(@"Duplicate Table...", @"duplicate table menu title")];
		[truncateTableButton setHidden:NO];
		[truncateTableButton setTitle:NSLocalizedString(@"Truncate Table...", @"truncate table menu title")];
		[removeTableMenuItem setTitle:NSLocalizedString(@"Delete Table...", @"delete table menu title")];
		[openTableInNewTabMenuItem setHidden:NO];
		[openTableInNewWindowMenuItem setHidden:NO];
		[openTableInNewTabMenuItem setTitle:NSLocalizedString(@"Open Table in New Tab", @"open table in new table title")];
		[openTableInNewWindowMenuItem setTitle:NSLocalizedString(@"Open Table in New Window", @"Table List : Gear Menu : Duplicate connection to new window")];
        NSString * pinTableLocalizedString = NSLocalizedString(isCurrentSelectionPinned ? @"Unpin Table" : @"Pin Table", @"pin table menu item title");
		[pinTableMenuItem setHidden:NO];
        [pinTableMenuItem setTitle:pinTableLocalizedString];
		[separatorTableMenuItem3 setHidden:NO];
		[showCreateSyntaxMenuItem setHidden:NO];
		[showCreateSyntaxMenuItem setTitle:NSLocalizedString(@"Show Create Table Syntax...", @"show create table syntax menu item")];
		[copyCreateSyntaxMenuItem setHidden:NO];
		[copyCreateSyntaxMenuItem setTitle:NSLocalizedString(@"Copy Create Table Syntax",@"Table List : Context Menu : Copy CREATE syntax (single table)")];

		[renameTableContextMenuItem setHidden:NO];
		[renameTableContextMenuItem setTitle:NSLocalizedString(@"Rename Table...", @"rename table menu title")];
		[duplicateTableContextMenuItem setHidden:NO];
		[duplicateTableContextMenuItem setTitle:NSLocalizedString(@"Duplicate Table...", @"duplicate table menu title")];
		[truncateTableContextMenuItem setHidden:NO];
		[truncateTableContextMenuItem setTitle:NSLocalizedString(@"Truncate Table...", @"truncate table menu title")];
		[removeTableContextMenuItem setTitle:NSLocalizedString(@"Delete Table...", @"delete table menu title")];
		[openTableInNewTabContextMenuItem setHidden:NO];
		[openTableInNewWindowContextMenuItem setHidden:NO];
		[separatorTableContextMenuItem3 setHidden:NO];
		[openTableInNewTabContextMenuItem setTitle:NSLocalizedString(@"Open Table in New Tab", @"open table in new tab title")];
		[openTableInNewWindowContextMenuItem setTitle:NSLocalizedString(@"Open Table in New Window", @"Table List : Context Menu : Duplicate connection to new window")];
        [pinTableContextMenuItem setHidden:NO];
        [pinTableContextMenuItem setTitle:pinTableLocalizedString];
        [copyTableNameContextMenuItem setHidden:NO];
        [copyTableNameContextMenuItem setTitle:NSLocalizedString(@"Copy Table Name",@"Table List : Context Menu : copy Table's name")];
		[showCreateSyntaxContextMenuItem setHidden:NO];
		[showCreateSyntaxContextMenuItem setTitle:NSLocalizedString(@"Show Create Table Syntax...", @"show create table syntax menu item")];
		[copyCreateSyntaxContextMenuItem setHidden:NO];
		[copyCreateSyntaxContextMenuItem setTitle:NSLocalizedString(@"Copy Create Table Syntax",@"Table List : Gear Menu : Copy CREATE syntax (single table)")];
	}
	else if (selectedTableType == SPTableTypeProc) {
		[[tableSubMenu itemAtIndex:4] setTitle:NSLocalizedString(@"Copy Create Procedure Syntax", @"copy create proc syntax menu item")];
		[[tableSubMenu itemAtIndex:5] setTitle:NSLocalizedString(@"Show Create Procedure Syntax...", @"show create proc syntax menu item")];
		[[tableSubMenu itemAtIndex:6] setHidden:YES]; // divider
		[[tableSubMenu itemAtIndex:7] setHidden:YES]; // copy columns
		[[tableSubMenu itemAtIndex:8] setHidden:YES]; // divider
		[[tableSubMenu itemAtIndex:9] setHidden:YES];
		[[tableSubMenu itemAtIndex:10] setHidden:YES];
		[[tableSubMenu itemAtIndex:11] setHidden:YES]; // divider
		[[tableSubMenu itemAtIndex:12] setHidden:YES];
		[[tableSubMenu itemAtIndex:13] setHidden:YES];

		[renameTableMenuItem setHidden:NO];
		[renameTableMenuItem setTitle:NSLocalizedString(@"Rename Procedure...", @"rename proc menu title")];
		[duplicateTableMenuItem setHidden:NO];
		[duplicateTableMenuItem setTitle:NSLocalizedString(@"Duplicate Procedure...", @"duplicate proc menu title")];
		[truncateTableButton setHidden:YES];
		[removeTableMenuItem setTitle:NSLocalizedString(@"Delete Procedure", @"delete proc menu title")];
		[openTableInNewTabMenuItem setHidden:NO];
		[openTableInNewWindowMenuItem setHidden:NO];
		[openTableInNewTabMenuItem setTitle:NSLocalizedString(@"Open Procedure in New Tab", @"open procedure in new table title")];
		[openTableInNewWindowMenuItem setTitle:NSLocalizedString(@"Open Procedure in New Window", @"Table List : Gear Menu : duplicate connection to new window")];
        NSString * pinProcedureLocalizedString = NSLocalizedString(isCurrentSelectionPinned ? @"Unpin Procedure" : @"Pin Procedure", @"pin procedure menu item title");
        [pinTableMenuItem setHidden:NO];
        [pinTableMenuItem setTitle:pinProcedureLocalizedString];
		[separatorTableMenuItem3 setHidden:NO];
		[showCreateSyntaxMenuItem setHidden:NO];
		[showCreateSyntaxMenuItem setTitle:NSLocalizedString(@"Show Create Procedure Syntax...", @"show create proc syntax menu item")];
		[copyCreateSyntaxMenuItem setHidden:NO];
		[copyCreateSyntaxMenuItem setTitle:NSLocalizedString(@"Copy Create Procedure Syntax",@"Table List : Gear Menu : Copy CREATE PROCEDURE syntax")];

		[renameTableContextMenuItem setHidden:NO];
		[renameTableContextMenuItem setTitle:NSLocalizedString(@"Rename Procedure...", @"rename proc menu title")];
		[duplicateTableContextMenuItem setHidden:NO];
		[duplicateTableContextMenuItem setTitle:NSLocalizedString(@"Duplicate Procedure...", @"duplicate proc menu title")];
		[truncateTableContextMenuItem setHidden:YES];
		[removeTableContextMenuItem setTitle:NSLocalizedString(@"Delete Procedure", @"delete proc menu title")];
		[openTableInNewTabContextMenuItem setHidden:NO];
		[openTableInNewWindowContextMenuItem setHidden:NO];
        [pinTableContextMenuItem setHidden:NO];
        [pinTableContextMenuItem setTitle:pinProcedureLocalizedString];
        [copyTableNameContextMenuItem setHidden:NO];
        [copyTableNameContextMenuItem setTitle:NSLocalizedString(@"Copy Table Name",@"Table List : Context Menu : copy Table's name")];
		[separatorTableContextMenuItem3 setHidden:NO];
		[openTableInNewTabContextMenuItem setTitle:NSLocalizedString(@"Open Procedure in New Tab", @"open procedure in new table title")];
		[openTableInNewWindowContextMenuItem setTitle:NSLocalizedString(@"Open Procedure in New Window", @"Table List : Context Menu : duplicate connection to new window")];
		[showCreateSyntaxContextMenuItem setHidden:NO];
		[showCreateSyntaxContextMenuItem setTitle:NSLocalizedString(@"Show Create Procedure Syntax...", @"show create proc syntax menu item")];
		[copyCreateSyntaxContextMenuItem setHidden:NO];
		[copyCreateSyntaxContextMenuItem setTitle:NSLocalizedString(@"Copy Create Procedure Syntax",@"Table List : Context Menu : Copy CREATE PROCEDURE syntax")];
	}
	else if (selectedTableType == SPTableTypeFunc) {
		[[tableSubMenu itemAtIndex:4] setTitle:NSLocalizedString(@"Copy Create Function Syntax", @"copy create func syntax menu item")];
		[[tableSubMenu itemAtIndex:5] setTitle:NSLocalizedString(@"Show Create Function Syntax...", @"show create func syntax menu item")];
		[[tableSubMenu itemAtIndex:6] setHidden:YES]; // divider
		[[tableSubMenu itemAtIndex:7] setHidden:YES]; // copy columns
		[[tableSubMenu itemAtIndex:8] setHidden:YES]; // divider
		[[tableSubMenu itemAtIndex:9] setHidden:YES];
		[[tableSubMenu itemAtIndex:10] setHidden:YES];
		[[tableSubMenu itemAtIndex:11] setHidden:YES]; // divider
		[[tableSubMenu itemAtIndex:12] setHidden:YES];
		[[tableSubMenu itemAtIndex:13] setHidden:YES];

		[renameTableMenuItem setHidden:NO];
		[renameTableMenuItem setTitle:NSLocalizedString(@"Rename Function...", @"rename func menu title")];
		[duplicateTableMenuItem setHidden:NO];
		[duplicateTableMenuItem setTitle:NSLocalizedString(@"Duplicate Function...", @"duplicate func menu title")];
		[truncateTableButton setHidden:YES];
		[removeTableMenuItem setTitle:NSLocalizedString(@"Delete Function", @"delete func menu title")];
		[openTableInNewTabMenuItem setHidden:NO];
		[openTableInNewWindowMenuItem setHidden:NO];
		[separatorTableMenuItem3 setHidden:NO];
		[openTableInNewTabMenuItem setTitle:NSLocalizedString(@"Open Function in New Tab", @"open function in new table title")];
		[openTableInNewWindowMenuItem setTitle:NSLocalizedString(@"Open Function in New Window", @"Table List : Gear Menu : duplicate connection to new window")];
        NSString * pinFunctionLocalizedString = NSLocalizedString(isCurrentSelectionPinned ? @"Unpin Function" : @"Pin Function", @"pin function menu item title");
        [pinTableMenuItem setHidden:NO];
        [pinTableMenuItem setTitle:pinFunctionLocalizedString];
		[showCreateSyntaxMenuItem setHidden:NO];
		[showCreateSyntaxMenuItem setTitle:NSLocalizedString(@"Show Create Function Syntax...", @"show create func syntax menu item")];
		[copyCreateSyntaxMenuItem setHidden:NO];
		[copyCreateSyntaxMenuItem setTitle:NSLocalizedString(@"Copy Create Function Syntax",@"Table List : Context Menu : copy CREATE FUNCTION syntax")];

		[renameTableContextMenuItem setHidden:NO];
		[renameTableContextMenuItem setTitle:NSLocalizedString(@"Rename Function...", @"rename func menu title")];
		[duplicateTableContextMenuItem setHidden:NO];
		[duplicateTableContextMenuItem setTitle:NSLocalizedString(@"Duplicate Function...", @"duplicate func menu title")];
		[truncateTableContextMenuItem setHidden:YES];
		[removeTableContextMenuItem setTitle:NSLocalizedString(@"Delete Function", @"delete func menu title")];
		[openTableInNewTabContextMenuItem setHidden:NO];
		[openTableInNewWindowContextMenuItem setHidden:NO];
		[separatorTableContextMenuItem3 setHidden:NO];
		[openTableInNewTabContextMenuItem setTitle:NSLocalizedString(@"Open Function in New Tab", @"open function in new table title")];
		[openTableInNewWindowContextMenuItem setTitle:NSLocalizedString(@"Open Function in New Window", @"Table List : Context Menu : duplicate connection to new window")];
        [pinTableContextMenuItem setHidden:NO];
        [pinTableContextMenuItem setTitle:pinFunctionLocalizedString];
        [copyTableNameContextMenuItem setHidden:NO];
        [copyTableNameContextMenuItem setTitle:NSLocalizedString(@"Copy Table Name",@"Table List : Context Menu : copy Table's name")];
		[showCreateSyntaxContextMenuItem setHidden:NO];
		[showCreateSyntaxContextMenuItem setTitle:NSLocalizedString(@"Show Create Function Syntax...", @"show create func syntax menu item")];
		[copyCreateSyntaxContextMenuItem setHidden:NO];
		[copyCreateSyntaxContextMenuItem setTitle:NSLocalizedString(@"Copy Create Function Syntax",@"Table List : Context Menu : copy CREATE FUNCTION syntax")];
	}
}

- (void)deselectAllTables
{
	[[tablesListView onMainThread] deselectAll:self];
}

#pragma mark -
#pragma mark Getter methods

- (NSArray *)selectedTableAndViewNames
{
	NSIndexSet *indexes = [tablesListView selectedRowIndexes];

	NSMutableArray *selTables = [NSMutableArray arrayWithCapacity:[indexes count]];

	[indexes enumerateIndexesUsingBlock:^(NSUInteger currentIndex, BOOL * _Nonnull stop) {
        NSInteger tableTypeIndex = [[filteredTableTypes objectAtIndex:currentIndex] integerValue];
		if(tableTypeIndex == SPTableTypeTable || tableTypeIndex == SPTableTypeView)
			[selTables addObject:[filteredTables objectAtIndex:currentIndex]];
	}];

	return selTables;
}

- (NSArray *)selectedTableItems
{
	NSIndexSet *indexes = [tablesListView selectedRowIndexes];

	NSMutableArray *selTables = [NSMutableArray arrayWithCapacity:[indexes count]];

	[indexes enumerateIndexesUsingBlock:^(NSUInteger currentIndex, BOOL * _Nonnull stop) {
		[selTables addObject:[filteredTables objectAtIndex:currentIndex]];
	}];

	return selTables;
}

- (NSArray *)selectedTableTypes
{
	NSIndexSet *indexes = [tablesListView selectedRowIndexes];

	NSMutableArray *selTables = [NSMutableArray arrayWithCapacity:[indexes count]];

	[indexes enumerateIndexesUsingBlock:^(NSUInteger currentIndex, BOOL * _Nonnull stop) {
		[selTables addObject:[filteredTableTypes objectAtIndex:currentIndex]];
	}];
	
	return selTables;
}

/**
 * Returns the currently selected table or nil if no table or mulitple tables are selected
 */
- (NSString *)tableName
{
	return selectedTableName;
}

/**
 * Returns the currently selected table type, or -1 if no table or multiple tables are selected
 */
- (SPTableType) tableType
{
	return selectedTableType;
}

/**
 * Database tables accessor
 */
- (NSArray *)tables
{
	return tables;
}

/**
 * Database tables accessor
 */
- (NSArray *)pinnedTables
{
    return pinnedTables;
}

/**
 * Database tables accessors for a given table type.
 */
- (NSArray *)allTableAndViewNames
{
	NSMutableArray *returnArray = [NSMutableArray array];

	for (NSUInteger i = 0; i <  [[self tables] count]; i++)
	{
		SPTableType tt = (SPTableType)[[[self tableTypes] safeObjectAtIndex: i] integerValue];

		if (tt == SPTableTypeTable || tt == SPTableTypeView) {
			[returnArray addObject:[[self tables] safeObjectAtIndex: i]];
		}
	}

	return returnArray;
}

/**
 * Returns an array of all table names.
 */
- (NSArray *)allTableNames
{
	return [self _allSchemaObjectsOfType:SPTableTypeTable];
}

/**
 * Returns an array of view names.
 */
- (NSArray *)allViewNames
{
	NSMutableArray *returnArray = [self _allSchemaObjectsOfType:SPTableTypeView];

	[returnArray sortUsingSelector:@selector(compare:)];

	return returnArray;
}

/**
 * Returns an array of all procedure names.
 */
- (NSArray *)allProcedureNames
{
	return [self _allSchemaObjectsOfType:SPTableTypeProc];
}

/**
 * Returns an array of all function names.
 */
- (NSArray *)allFunctionNames
{
	return [self _allSchemaObjectsOfType:SPTableTypeFunc];
}

/**
 * Returns an array of event names.
 */
- (NSArray *)allEventNames
{
	return [self _allSchemaObjectsOfType:SPTableTypeEvent];
}

/**
 * Returns an array of all available database names
 */
- (NSArray *)allDatabaseNames
{
	return [tableDocumentInstance allDatabaseNames];
}

- (NSString *)selectedDatabase
{
	return [tableDocumentInstance database];
}

/**
 * Returns an array of all available database names
 */
- (NSArray *)allSystemDatabaseNames
{
	return [tableDocumentInstance allSystemDatabaseNames];
}

/**
 * Database table types accessor
 */
- (NSArray *)tableTypes
{
	return tableTypes;
}

/**
 * Returns whether or not the current database contains any views.
 */
- (BOOL)hasViews
{
	return [self _databaseHasObjectOfType:SPTableTypeView];
}

/**
 * Returns whether or not the current database contains any functions.
 */
- (BOOL)hasFunctions
{
	return [self _databaseHasObjectOfType:SPTableTypeFunc];
}

/**
 * Returns whether or not the current database has any procedures.
 */
- (BOOL)hasProcedures
{
	return [self _databaseHasObjectOfType:SPTableTypeProc];
}

/**
 * Returns whether or not the current database has any events.
 */
- (BOOL)hasEvents
{
	return [self _databaseHasObjectOfType:SPTableTypeEvent];
}

/**
 * Returns whether or not the current database has any non-table objects.
 */
- (BOOL)hasNonTableObjects
{
	return [self hasViews] || [self hasProcedures] || [self hasFunctions] || [self hasEvents];
}

#pragma mark -
#pragma mark Setter methods

/**
 * Select an item using the provided name; returns YES if the
 * supplied name could be selected, or NO if not.
 *
 * MUST BE CALLED ON THE UI THREAD!
 */
- (BOOL)selectItemWithName:(NSString *)theName
{
	NSUInteger i;
	NSInteger tableType, itemIndex = NSNotFound;
	NSInteger caseInsensitiveItemIndex = NSNotFound;

	// Loop through the unfiltered tables/views to find the desired item
	for (i = 0; i < [tables count]; i++) {
		tableType = [[tableTypes objectAtIndex:i] integerValue];
		if (tableType == SPTableTypeNone) continue;
		if ([[tables objectAtIndex:i] isEqualToString:theName]) {
			itemIndex = i;
			break;
		}
		if ([[tables objectAtIndex:i] compare:theName options:NSCaseInsensitiveSearch|NSLiteralSearch] == NSOrderedSame)
			caseInsensitiveItemIndex = i;
	}

	// If no case-sensitive match was found, use a case-insensitive match if available
	if (itemIndex == NSNotFound && caseInsensitiveItemIndex != NSNotFound)
		itemIndex = caseInsensitiveItemIndex;

	// If no match found, return failure
	if (itemIndex == NSNotFound) return NO;

	if (!isTableListFiltered) {
		[tablesListView selectRowIndexes:[NSIndexSet indexSetWithIndex:itemIndex] byExtendingSelection:NO];
	}
	else {
		NSInteger filteredIndex = [filteredTables indexOfObject:[tables objectAtIndex:itemIndex]];

		if (filteredIndex != NSNotFound) {
			[tablesListView selectRowIndexes:[NSIndexSet indexSetWithIndex:filteredIndex] byExtendingSelection:NO];
		}
		else {
			[self deselectAllTables];
			
			selectedTableName = [[NSString alloc] initWithString:[tables objectAtIndex:itemIndex]];
			selectedTableType = (SPTableType)[[tableTypes objectAtIndex:itemIndex] integerValue];
			
			[self updateFilter:self];
			
			[tableDocumentInstance loadTable:selectedTableName ofType:selectedTableType];
		}
	}

	[tablesListView scrollRowToVisible:[tablesListView selectedRow]];

	return YES;
}

/**
 * Try to select items using the provided names in theNames; returns YES if at least
 * one item could be seleceted, otherwise NO.
 */
- (BOOL)selectItemsWithNames:(NSArray *)theNames
{
	NSUInteger i;
	NSInteger tableType;
	NSMutableIndexSet *selectionIndexSet = [NSMutableIndexSet indexSet];

	// Loop through the unfiltered tables/views to find the desired item
	for(NSString* theName in theNames) {
		for (i = 0; i < [tables count]; i++) {
			tableType = [[tableTypes objectAtIndex:i] integerValue];
			if (tableType == SPTableTypeNone) continue;
			if ([[tables objectAtIndex:i] isEqualToString:theName]) {
				[selectionIndexSet addIndex:i];
			}
			else if ([[tables objectAtIndex:i] compare:theName options:NSCaseInsensitiveSearch|NSLiteralSearch] == NSOrderedSame)
				[selectionIndexSet addIndex:i];
		}
	}

	// If no match found, return failure
	if (![selectionIndexSet count]) return NO;

	if (!isTableListFiltered) {
		[tablesListView selectRowIndexes:selectionIndexSet byExtendingSelection:NO];
	}
	else {
		[self deselectAllTables];

		[listFilterField setStringValue:@""];

		[self updateFilter:self];

		[tablesListView selectRowIndexes:selectionIndexSet byExtendingSelection:NO];
	}

	[[tablesListView onMainThread] scrollRowToVisible:[tablesListView selectedRow]];

	return YES;
}

#pragma mark -
#pragma mark Data validation

/**
 * Check tableName for length and if the tableName doesn't match
 * against current database table/view names (case-insensitive).
 */
- (BOOL)isTableNameValid:(NSString *)tableName forType:(SPTableType)tableType
{
    return [self isTableNameValid:tableName forType:tableType ignoringSelectedTable:NO];
}

/**
 * Check tableName for length and if the tableName doesn't match
 * against current database table/view names (case-insensitive).
 */
- (BOOL)isTableNameValid:(NSString *)tableName forType:(SPTableType)tableType ignoringSelectedTable:(BOOL)ignoreSelectedTable
{
	BOOL isValid = YES;

	// delete trailing whitespaces since 'foo  ' or '   ' are not valid table names
	NSString *fieldStr = [tableName stringByMatching:@"(.*?)\\s*$" capture:1];
	NSString *lowercaseFieldStr = [fieldStr lowercaseString];

	// If table name has trailing whitespaces return 'no valid'
	if([fieldStr length] != [tableName length]) return NO;

	// empty table names are invalid
	if([fieldStr length] == 0) return NO;

	NSArray *similarTables;
	switch (tableType) {
		case SPTableTypeView:
		case SPTableTypeTable:
			similarTables = [self allTableAndViewNames];
			break;
		case SPTableTypeProc:
			similarTables = [self allProcedureNames];
			break;
		case SPTableTypeFunc:
			similarTables = [self allFunctionNames];
			break;
		default:
			// if some other table type is given, just return yes
			// better a mysql error than not being able to change something at all
			return YES;
	}

	for(id table in similarTables) {
		//compare case insensitive here
		if([lowercaseFieldStr isEqualToString:[table lowercaseString]]) {
			if (ignoreSelectedTable) {
				// if table is the selectedTable, ignore it
				// we must compare CASE SENSITIVE here!
				if ([table isEqualToString:selectedTableName]) continue;
			}
			isValid = NO;
			break;
		}
	}
	return isValid;
}

#pragma mark -
#pragma mark Datasource methods

/**
 * Returns the number of tables in the current database.
 */
- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{
	return [filteredTables count];
}

/**
 * Returns the table names to be displayed in the tables list table view.
 */
- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
	// During imports the table view sometimes appears to request items beyond the end of the array.
	// Using a hinted noteNumberOfRowsChanged after dropping tables fixes this but then seems to stick
	// even after override, so check here for the time being and display empty rows during import.
	if (rowIndex >= (NSInteger)[filteredTables count]) return @"";

	return [filteredTables objectAtIndex:rowIndex];
}

/**
 * Prevent table renames while tasks are active
 */
- (BOOL)tableView:(NSTableView *)aTableView shouldEditTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
	return ![tableDocumentInstance isWorking];
}

/**
 * Renames a table (in tables-array and mysql-db).
 */
- (void)tableView:(NSTableView *)aTableView setObjectValue:(id)anObject forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
	//first trim whitespace whitespace
	NSString *newTableName = [anObject stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	if ([selectedTableName isEqualToString:newTableName]) {
		// No changes in table name
		return;
	}

	if ([newTableName isEqualToString:@""]) {
		// empty table names are not allowed
		// don't annoy the user about it, just ignore this
		// this is also how the MacOS Finder handles renaming files
		return;
	}

	if (![self isTableNameValid:newTableName forType:selectedTableType ignoringSelectedTable:YES]) {
		// Table has invalid name, and since we trimmed whitespace and checked for empty string, this means there is already a table with that name
		[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:[NSString stringWithFormat: NSLocalizedString(@"The name '%@' is already used.", @"message when trying to rename a table/view/proc/etc to an already used name"), newTableName] callback:nil];
		return;
  }
  
  __block BOOL isRenamed = NO;
  if ([prefs boolForKey:SPQueryWarningEnabled]) {
    [NSAlert createDefaultAlertWithTitle:NSLocalizedString(@"Rename table", @"Rename table")
                                 message:[NSString stringWithFormat:NSLocalizedString(@"Do you want to rename '%@' table to '%@'?", @"rename table description"), 
                                          selectedTableName,
                                          newTableName]
                      primaryButtonTitle:NSLocalizedString(@"Confirm", @"Confirmation for renaming table")
                    primaryButtonHandler:^{
      [self renameTableOfType:self->selectedTableType from:self->selectedTableName to:newTableName];
      isRenamed = YES;
    }
                     cancelButtonHandler:nil];
  } else {
    [self renameTableOfType:selectedTableType from:selectedTableName to:newTableName];
    isRenamed = YES;
  }
  
  if (!isRenamed) {
    return;
  }

  // Set window title to reflect the new table name
  [tableDocumentInstance updateWindowTitle:self];
  
  // Query the structure of all databases in the background (mainly for completion)
  [[tableDocumentInstance databaseStructureRetrieval] queryDbStructureInBackgroundWithUserInfo:@{@"forceUpdate" : @YES}];
}

- (void) renameTableOfType:(SPTableType)tableType from:(NSString *)fromTableName to:(NSString *)toTableName {
  @try {
    // first: update the database
    [self _renameTableOfType:tableType from:fromTableName to:toTableName];
    
    // second : unpin fromTableName and pin toTableName
    [self handlePinnedTableRenameFrom:fromTableName To:toTableName];
    
    // third: do full refresh
    [self updateTables:self];
  }
  @catch (NSException * myException) {
    [NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:[myException reason] callback:nil];
  }
}

#pragma mark -
#pragma mark TableView delegate methods

/**
 * Traps enter and esc and edit/cancel without entering next row
 */
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
	
	if(control == listFilterField) {
		NSInteger newRow = NSNotFound;
		// Arrow down/up will usually go to start/end of the text field. we want to change the selected table row.
		if (command == @selector(moveDown:)) {
			newRow = [tablesListView selectedRow] + 1;
		}
		
		if (command == @selector(moveUp:)) {
			newRow = [tablesListView selectedRow] - 1;
		}
		
		if(newRow != NSNotFound) {
			//we can't go below 1 or we'll select the table header
			[tablesListView selectRowIndexes:[NSIndexSet indexSetWithIndex:(newRow > 0 ? newRow : 1)] byExtendingSelection:NO];
			return YES;
		}
	}
	else {
		// When enter/return is used, save the row.
		if ( [textView methodForSelector:command] == [textView methodForSelector:@selector(insertNewline:)] ) {
			[[control window] makeFirstResponder:control];
			return YES;
		}
		// When the escape key is used, abort the rename.
		else if ( [[control window] methodForSelector:command] == [[control window] methodForSelector:@selector(cancelOperation:)] ||
				   [textView methodForSelector:command] == [textView methodForSelector:@selector(complete:)] ) {
			
			[control abortEditing];
			[[tablesListView window] makeFirstResponder:tablesListView];
			
			return YES;
		}
	}
	
	return NO;
}

/**
 * Table view delegate method
 */
- (BOOL)selectionShouldChangeInTableView:(nullable NSTableView *)aTableView
{
	// Don't allow selection changes while performing a task.
	if (!tableListIsSelectable) return NO;

	// End editing (otherwise problems when user hits reload button)
	[[tableDocumentInstance parentWindowControllerWindow] endEditingFor:nil];

	// We have to be sure that document views have finished editing
	return [tableDocumentInstance couldCommitCurrentViewActions];
}

/**
 * Loads a table in content or source view (if tab selected)
 */
- (void)tableViewSelectionDidChange:(NSNotification *)aNotification
{
	if ([tablesListView numberOfSelectedRows] != 1) {

		// Ensure the state is cleared
		if ([tableDocumentInstance table]) {
			[tableDocumentInstance loadTable:nil ofType:SPTableTypeNone];
		} 
		else {
			[self setSelectionState:nil];
			[tableInfoInstance tableChanged:nil];
		}
		
		if (selectedTableName) selectedTableName = nil;
		
		selectedTableType = SPTableTypeNone;
		
		return;
	}

	NSInteger selectedRowIndex = [tablesListView selectedRow];

	if (![[filteredTables objectAtIndex:selectedRowIndex] isKindOfClass:[NSString class]]) return;

	// Reset selectability after change if necessary
	if ([tableDocumentInstance isWorking]) tableListIsSelectable = NO;

	// Perform no action if the selected table hasn't actually changed - reselection etc
	NSString *newName = [filteredTables objectAtIndex:selectedRowIndex];
	SPTableType newType = (SPTableType)[[filteredTableTypes objectAtIndex:selectedRowIndex] integerValue];
	
	if ([selectedTableName isEqualToString:newName] && selectedTableType == newType) return;

	// Save existing scroll position and details
	[spHistoryControllerInstance updateHistoryEntries];

	
	
	selectedTableName = [[NSString alloc] initWithString:newName];
	selectedTableType = newType;
	
	[tableDocumentInstance loadTable:selectedTableName ofType:selectedTableType];

	if ([[SPNavigatorController sharedNavigatorController] syncMode]) {
		NSMutableString *schemaPath = [NSMutableString string];
		
		[schemaPath setString:[tableDocumentInstance connectionID]];
		
		if ([tableDocumentInstance database] && [[tableDocumentInstance database] length]) {
			[schemaPath appendString:SPUniqueSchemaDelimiter];
			[schemaPath appendString:[tableDocumentInstance database]];
			[schemaPath appendString:SPUniqueSchemaDelimiter];
			[schemaPath appendString:selectedTableName];
		}
		
		[[SPNavigatorController sharedNavigatorController] selectPath:schemaPath];
	}
}

/**
 * Table view delegate method
 */
- (BOOL)tableView:(NSTableView *)aTableView shouldSelectRow:(NSInteger)rowIndex
{
	// Disallow selection while the document is working on a task
	if ([tableDocumentInstance isWorking]) {
		return NO;
	}

	// Allow deselections
	if (rowIndex == -1) {
		return YES;
	}

	// On 10.6, right-clicking below all rows attempts to select a high row index
	if (rowIndex >= (NSInteger)[filteredTables count]) {
		return NO;
	}

	if (![[filteredTables objectAtIndex:rowIndex] isKindOfClass:[NSString class]]) {
		return NO;
	}

	if ([filteredTableTypes count] == 0) {
		return (rowIndex != 0 );
	}

	return ([[filteredTableTypes objectAtIndex:rowIndex] integerValue] != SPTableTypeNone);
}

/**
 * Table view delegate method
 */
- (BOOL)tableView:(NSTableView *)aTableView isGroupRow:(NSInteger)rowIndex
{
	// For empty tables - title still present - or while lists are being altered
	if (rowIndex >= (NSInteger)[filteredTableTypes count]) return (rowIndex == 0 );

	return ([[filteredTableTypes objectAtIndex:rowIndex] integerValue] == SPTableTypeNone );
}

/**
 * Table view delegate method
 */
- (void)tableView:(NSTableView *)aTableView  willDisplayCell:(SPTableTextFieldCell
 *)aCell forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
	if (rowIndex > 0 && rowIndex < (NSInteger)[filteredTableTypes count] && [[aTableColumn identifier] isEqualToString:@"tables"]) {

		id item = [filteredTables safeObjectAtIndex:rowIndex];

		if(![item isKindOfClass:[NSString class]]) {
			[aCell setImage:nil];
			[aCell setIndentationLevel:0];
			return;
		}
		
		id comment = [tableComments objectForKey:item];
		
		if([comment isKindOfClass:[NSString class]] && [prefs boolForKey:SPDisplayCommentsInTablesList]) {
			[aCell setNote:comment];
		}

		switch([[filteredTableTypes safeObjectAtIndex:rowIndex] integerValue]) {
			case SPTableTypeView:
				[aCell setImage:[NSImage imageNamed:@"table-view-small"]];
				[aCell setIndentationLevel:0];
				break;
			case SPTableTypeTable:
				[aCell setImage:[NSImage imageNamed:@"table-small"]];
				[aCell setIndentationLevel:0];
				break;
			case SPTableTypeProc:
				[aCell setImage:[NSImage imageNamed:@"proc-small"]];
				[aCell setIndentationLevel:0];
				break;
			case SPTableTypeFunc:
				[aCell setImage:[NSImage imageNamed:@"func-small"]];
				[aCell setIndentationLevel:0];
				break;
			case SPTableTypeNone:
				[aCell setImage:nil];
				[aCell setIndentationLevel:0];
				break;
			default:
				[aCell setIndentationLevel:0];
		}

	} 
	else {
		[aCell setNote:@""];
		[aCell setImage:nil];
		[aCell setIndentationLevel:0];
	}
}

/**
 * Table view delegate method
 */
- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row
{
	if (row == 0) {
		return 25;
	} else {
		NSFont *tableFont = [NSUserDefaults getFont];
		return 4.0f + NSSizeToCGSize([@"{ǞṶḹÜ∑zgyf" sizeWithAttributes:@{NSFontAttributeName : tableFont}]).height;
	}
}

- (BOOL)tableView:(NSTableView *)aTableView acceptDrop:(id <NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation
{
	NSPasteboard *pboard = [info draggingPasteboard];

	// tables were dropped coming from the Navigator
	if ( [[pboard types] containsObject:SPNavigatorTableDataPasteboardDragType] ) {
		NSString *query = [pboard stringForType:SPNavigatorTableDataPasteboardDragType];
		if(!query) return NO;

		[mySQLConnection queryString:query];
		if ([mySQLConnection queryErrored]) {
			[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error while importing table", @"error while importing table message") message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while trying to import a table via: \n%@\n\n\nMySQL said: %@", @"error importing table informative message"), query, [mySQLConnection lastErrorMessage]] callback:nil];
			return NO;
		}
		[self updateTables:nil];
		return YES;
	}

	return NO;
}

- (NSDragOperation)tableView:(NSTableView *)aTableView validateDrop:(id < NSDraggingInfo >)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)operation
{
	[tablesListView setDropRow:row dropOperation:NSTableViewDropAbove];
	
	return NSDragOperationCopy;
}

#pragma mark -
#pragma mark Interface validation

/**
 * Menu item interface validation
 */
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	SEL action = [menuItem action];
	NSInteger selectedRows = [tablesListView numberOfSelectedRows];

	if (action == @selector(copyTable:) || 
		action == @selector(renameTable:) ||
		action == @selector(openTableInNewTab:) ||
		action == @selector(openTableInNewWindow:))
	{
		return selectedRows == 1 && [[self tableName] length];
	}

	if (action == @selector(removeTable:) ||
		action == @selector(truncateTable:))
	{
		return selectedRows > 0;
	}

	//Default to YES (like Apple)
	return YES;
}

#pragma mark -
#pragma mark Table list filter interaction

/**
 * Show the filter box if it's currently hidden.  Use a delay to ensure
 * action is executed on first load.
 */
- (void) showFilter
{
	if ([tableListFilterSplitView isCollapsibleSubviewCollapsed]) {
		[tableListFilterSplitView performSelectorOnMainThread:@selector(toggleCollapse:) withObject:nil waitUntilDone:NO];
	}
}

/**
 * Hide the filter box if it's currently shown.  Use a delay to ensure
 * action is executed on first load.
 */
- (void) hideFilter
{
	if (![tableListFilterSplitView isCollapsibleSubviewCollapsed]) {
		[tableListFilterSplitView performSelectorOnMainThread:@selector(toggleCollapse:) withObject:nil waitUntilDone:NO];
	}
}

/**
 * Clear the current content of the filter box
 */
- (void) clearFilter
{
	[listFilterField setStringValue:@""];
}

/**
 * Refresh the current pinned tables and reload the UI
 */
- (void)refreshPinnedTables {

    [self removePinnedTablesSection];
    [self initPinnedTables];
    [[tablesListView onMainThread] reloadData];
    
}

/**
 * Remove all currently pinned tables,
 * Doesn't reload the UI
 */
- (void)removePinnedTablesSection {
    [pinnedTables removeAllObjects];
    NSString * pinnedHeader = NSLocalizedString(@"PINNED", @"header for pinned tables");
    while ([tables count] > 0) {
        if ([[tableTypes objectAtIndex:0] isEqual:@(SPTableTypeNone)] && [[tables objectAtIndex:0] isNotEqualTo:pinnedHeader]) {
            break;
        }
        [tables removeObjectAtIndex:0];
        [tableTypes removeObjectAtIndex:0];
    }
}

/**
 * Initialises pinned table from database, no tables can be already pinned when this method is invoked
 * Doesn't reload the UI
 */
- (void)initPinnedTables {
    NSString * hostName = [mySQLConnection host];
    NSString * databaseName = [mySQLConnection database];
    NSArray *tablesToPin = [_SQLitePinnedTableManager getPinnedTablesWithHostName:hostName databaseName:databaseName];
    if (tablesToPin.count > 0) {
        [tables insertObject:NSLocalizedString(@"PINNED", @"header for pinned tables") atIndex:0];
        [tableTypes insertObject:@(SPTableTypeNone) atIndex:0];
        NSSortDescriptor* sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:nil ascending:NO selector:@selector(localizedCompare:)];
        NSArray* sortedPinnedTables = [tablesToPin sortedArrayUsingDescriptors:@[sortDescriptor]];
        // sorted in descending alphabetical order because of how the data is subsequently added to tables array
        for (NSString *tableToPin in sortedPinnedTables) {
            if ([tables indexOfObject:tableToPin] == NSNotFound) {
                continue;
            }
            [pinnedTables addObject:tableToPin];
            SPTableType tableType = (SPTableType) [tableTypes[[tables indexOfObject:tableToPin]] integerValue];
            [tables insertObject:tableToPin atIndex:1];
            [tableTypes insertObject:@(tableType) atIndex:1];
        }
    }
}

- (void)handlePinnedTableRenameFrom: (NSString*) originalTableName To: (NSString*) newTableName {

    NSString *databaseName = [mySQLConnection database];
    NSString *hostName = [mySQLConnection host];

    if ([pinnedTables containsObject:originalTableName]) {
        [_SQLitePinnedTableManager unpinTableWithHostName:hostName databaseName:databaseName tableToUnpin:originalTableName];
        if (![pinnedTables containsObject:newTableName]) {
            [_SQLitePinnedTableManager pinTableWithHostName:hostName databaseName:databaseName tableToPin:newTableName];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:pinnedTableNotificationName object:nil];
    }
    
}

- (void)unpinDeletedTableIfPinned: (NSString*) tableName {

    NSString *databaseName = [mySQLConnection database];
    NSString *hostName = [mySQLConnection host];

    if ([pinnedTables containsObject:tableName]) {
        [_SQLitePinnedTableManager unpinTableWithHostName:hostName databaseName:databaseName tableToUnpin:tableName];
        [[NSNotificationCenter defaultCenter] postNotificationName:pinnedTableNotificationName object:nil];
    }
    
}


- (void)subscribeToTablePinningNotifications {
    
    NSString * hostName = [mySQLConnection host];
    NSString * databaseName = [mySQLConnection database];
    
    // remove observer for previous hostname+database on database selection change by user
    if (pinnedTableNotificationName != nil) {
        [[NSNotificationCenter defaultCenter]
            removeObserver:self
            name:pinnedTableNotificationName
            object:nil];
    }
    
    // craft notification name such that notification goes only to tabs with same hostname+database
    pinnedTableNotificationName = [NSString stringWithFormat:@"PinnedTableNotification-Host:%@-Database:%@", hostName, databaseName];
    
    [[NSNotificationCenter defaultCenter]
        addObserver:self
        selector:@selector(processPinTableNotification:)
        name:pinnedTableNotificationName
        object:nil];
}

- (void)processPinTableNotification:(nonnull NSNotification *) notification; {
    [self refreshPinnedTables];
    if (selectedTableName!=nil) {
        [self selectItemWithName:selectedTableName]; // so that correct table stays selected with insertion/removal of pinned tables
        [[self onMainThread] setSelectionState:@{@"name": selectedTableName, @"type": @(selectedTableType)}]; // to refresh items in context menus
    }
    if (isTableListFiltered) {
        [self updateFilter:self];
    }
}


/**
 * Set focus to table list filter search field, or the table list if the filter
 * field is not visible.
 */
- (void) makeTableListFilterHaveFocus
{
    SPMainLoopAsync(^{
        [[self->tableDocumentInstance parentWindowControllerWindow] makeFirstResponder:self->listFilterField];
    });
}

/**
 * Set focus to the table list.
 */
- (void) makeTableListHaveFocus
{
	[[tableDocumentInstance parentWindowControllerWindow] makeFirstResponder:tablesListView];
}

/**
 * Update the filter search.
 */
- (IBAction)updateFilter:(id)sender
{
	// Don't try and maintain selections of multiple rows through filtering
	if ([tablesListView numberOfSelectedRows] > 1) {
		[self deselectAllTables];

		if (selectedTableName) selectedTableName = nil;
	}

	if ([[listFilterField stringValue] length]) {
		filteredTables = [[NSMutableArray alloc] init];
		filteredTableTypes = [[NSMutableArray alloc] init];

		NSUInteger i;
		NSInteger lastTableType = NSNotFound, tableType;
		NSRange substringRange;
		NSString *filterString = [listFilterField stringValue];
		BOOL isPinnedTablesSection = 0;
        NSString * pinnedHeader = NSLocalizedString(@"PINNED", @"header for pinned tables");
		for (i = 0; i < [tables count]; i++) {
			tableType = [[tableTypes objectAtIndex:i] integerValue];
			if (tableType == SPTableTypeNone) {
				if ([tables[i] isEqualTo:pinnedHeader]) { // pinned tables start
					isPinnedTablesSection = 1;
					[filteredTables addObject:pinnedHeader];
					[filteredTableTypes addObject:@(SPTableTypeNone)];
				}
				else { // pinned tables end
					isPinnedTablesSection = 0;
				}
				continue;
			}

			if (isPinnedTablesSection) {
				[filteredTables addObject:[tables objectAtIndex:i]];
				[filteredTableTypes addObject:[tableTypes objectAtIndex:i]];
				continue;
			}

			// First check the table name against the string as a regex, falling back to direct string match
			if (![[tables objectAtIndex:i] isMatchedByRegex:filterString]) {
				substringRange = [[tables objectAtIndex:i] rangeOfString:filterString options:NSCaseInsensitiveSearch];
				if (substringRange.location == NSNotFound) continue;
			}

			// Add a title if necessary
			if ((tableType == SPTableTypeTable || tableType == SPTableTypeView) && lastTableType == NSNotFound)
			{
				if (tableListContainsViews) {
					[filteredTables addObject:NSLocalizedString(@"TABLES & VIEWS",@"header for table & views list")];
				} else {
					[filteredTables addObject:NSLocalizedString(@"TABLES",@"header for table list")];
				}
				[filteredTableTypes addObject:[NSNumber numberWithInteger:SPTableTypeNone]];
			} else if ((tableType == SPTableTypeProc || tableType == SPTableTypeFunc)
						&& (lastTableType == NSNotFound || lastTableType == SPTableTypeTable || lastTableType == SPTableTypeView))
			{
				[filteredTables addObject:NSLocalizedString(@"PROCS & FUNCS",@"header for procs & funcs list")];
				[filteredTableTypes addObject:[NSNumber numberWithInteger:SPTableTypeNone]];
			}
			lastTableType = tableType;

			// Add the item
			[filteredTables addObject:[tables objectAtIndex:i]];
			[filteredTableTypes addObject:[tableTypes objectAtIndex:i]];
		}

		// Add a "no matches" title if nothing matches the current filter settings
		if (![filteredTables count]) {
			[filteredTables addObject:NSLocalizedString(@"NO MATCHES",@"header for no matches in filtered list")];
			[filteredTableTypes addObject:[NSNumber numberWithInteger:SPTableTypeNone]];
		}

		// If the currently selected table isn't present in the filter list, add it as a special entry
		if (selectedTableName && [filteredTables indexOfObject:selectedTableName] == NSNotFound) {
			[filteredTables addObject:NSLocalizedString(@"CURRENT SELECTION",@"header for current selection in filtered list")];
			[filteredTableTypes addObject:[NSNumber numberWithInteger:SPTableTypeNone]];
			[filteredTables addObject:selectedTableName];
			[filteredTableTypes addObject:[NSNumber numberWithInteger:selectedTableType]];
		}

		isTableListFiltered = YES;
	} 
	else if (isTableListFiltered) {
		isTableListFiltered = NO;
		filteredTables = tables;
		filteredTableTypes = tableTypes;
	}

	// Reselect correct row and reload the table view display
	if ([tablesListView numberOfRows] < (NSInteger)[filteredTables count]) [tablesListView noteNumberOfRowsChanged];

    if (selectedTableName && [filteredTables indexOfObject:selectedTableName] < NSNotFound){
        [tablesListView selectRowIndexes:[NSIndexSet indexSetWithIndex:[filteredTables indexOfObject:selectedTableName]] byExtendingSelection:NO];
    }
	[tablesListView reloadData];
}

/**
 * Select the supplied row index; added for convenience to allow
 * use with performSelector:withObject:afterDelay: for re-selection.
 */
- (void) selectTableAtIndex:(NSNumber *)row
{
	NSUInteger rowIndex = [row unsignedIntegerValue];
	if (rowIndex == NSNotFound || rowIndex > [filteredTables count] || [[filteredTableTypes objectAtIndex:rowIndex] integerValue] == SPTableTypeNone)
		return;

	[tablesListView selectRowIndexes:[NSIndexSet indexSetWithIndex:rowIndex] byExtendingSelection:NO];
}

#pragma mark -
#pragma mark Task interaction

/**
 * Disable all table list interactive elements during an ongoing task.
 */
- (void) startDocumentTaskForTab:(NSNotification *)aNotification
{
	tableListIsSelectable = NO;
	[toolbarAddButton setEnabled:NO];
	[toolbarActionsButton setEnabled:NO];
	[toolbarReloadButton setEnabled:NO];
}

/**
 * Enable all table list interactive elements after an ongoing task.
 */
- (void) endDocumentTaskForTab:(NSNotification *)aNotification
{
	tableListIsSelectable = YES;
	[toolbarAddButton setEnabled:YES];
	[toolbarActionsButton setEnabled:YES];
	[toolbarReloadButton setEnabled:YES];
}

/**
 * Set the table list to selectable or not during the task process.
 */
- (void) setTableListSelectability:(BOOL)isSelectable
{
	tableListIsSelectable = isSelectable;
}

#pragma mark -
#pragma mark Private API

/**
 * Removes the selected object (table, view, procedure, function, etc.) from the database and tableView.
 */
- (void)_removeTable:(BOOL)force
{
	NSIndexSet *indexes = [tablesListView selectedRowIndexes];
	
	[tablesListView selectRowIndexes:[NSIndexSet indexSet] byExtendingSelection:NO];

	// Get last index
	NSUInteger currentIndex = [indexes lastIndex];
	
	if (force) {
		[mySQLConnection queryString:@"SET FOREIGN_KEY_CHECKS = 0"];
	}

	while (currentIndex != NSNotFound) {
		NSString *objectIdentifier = @"";
        NSString *databaseObjectName = [filteredTables objectAtIndex:currentIndex];
		NSString *databaseObject = [databaseObjectName backtickQuotedString];
		NSInteger objectType = [[filteredTableTypes objectAtIndex:currentIndex] integerValue];
		
		if (objectType == SPTableTypeView) {
			objectIdentifier = @"VIEW";
		} 
		else if (objectType == SPTableTypeTable) {
			objectIdentifier = @"TABLE";
		}
		else if (objectType == SPTableTypeProc) {
			objectIdentifier = @"PROCEDURE";
		} 
		else if (objectType == SPTableTypeFunc) {
			objectIdentifier = @"FUNCTION";
		}
		
		[mySQLConnection queryString:[NSString stringWithFormat:@"DROP %@ %@", objectIdentifier, databaseObject]];

		// If no error is recorded, the table was successfully dropped - remove it from the list
		if (![mySQLConnection queryErrored]) {
			
			// Dropped table with success
			if (isTableListFiltered) {
				NSInteger unfilteredIndex = [tables indexOfObject:[filteredTables objectAtIndex:currentIndex]];
				
				[tables removeObjectAtIndex:unfilteredIndex];
				[tableTypes removeObjectAtIndex:unfilteredIndex];
			}
			
			[filteredTables removeObjectAtIndex:currentIndex];
			[filteredTableTypes removeObjectAtIndex:currentIndex];

			// Get next index (beginning from the end)
			currentIndex = [indexes indexLessThanIndex:currentIndex];
		} 
		// Otherwise, display an alert - and if there's tables left, ask whether to proceed
		else {
			NSAlert *alert = [[NSAlert alloc] init];
			
			if ([indexes indexLessThanIndex:currentIndex] == NSNotFound) {
				[alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
			} else {
				[alert addButtonWithTitle:NSLocalizedString(@"Continue", @"continue button")];
				[alert addButtonWithTitle:NSLocalizedString(@"Stop", @"stop button")];
			}
			
			NSString *databaseError = [mySQLConnection lastErrorMessage];
			NSString *userMessage = NSLocalizedString(@"Couldn't delete '%@'.\n\nMySQL said: %@", @"message of panel when an item cannot be deleted");
			
			// Try to provide a more helpful message
			if ([databaseError rangeOfString:@"a foreign key constraint fails" options:NSCaseInsensitiveSearch].location != NSNotFound) {
				userMessage = NSLocalizedString(@"Couldn't delete '%@'.\n\nSelecting the 'Force delete' option may prevent this issue, but may leave the database in an inconsistent state.\n\nMySQL said: %@", @"message of panel when an item cannot be deleted including informative message about using force deletion");
			}
			
			[alert setMessageText:NSLocalizedString(@"Error", @"error")];
			[alert setInformativeText:[NSString stringWithFormat:userMessage, [filteredTables objectAtIndex:currentIndex], [mySQLConnection lastErrorMessage]]];
			[alert setAlertStyle:NSAlertStyleWarning];
			
			if ([indexes indexLessThanIndex:currentIndex] == NSNotFound) {
				[alert runModal];
				currentIndex = NSNotFound;
			} else {
				NSInteger choice = [alert runModal];
				
				currentIndex = (choice == NSAlertFirstButtonReturn) ? [indexes indexLessThanIndex:currentIndex] : NSNotFound;
			}
		}
        // Remove the table from pinned tables list if its pinned
        [self unpinDeletedTableIfPinned:databaseObjectName];
	}
	
	if (force) {
		[mySQLConnection queryString:@"SET FOREIGN_KEY_CHECKS = 1"];
	}

    [self updateTables:self]; // do full refresh

	[tableDocumentInstance updateWindowTitle:self];

	// Query the structure of all databases in the background (mainly for completion)
	[[tableDocumentInstance databaseStructureRetrieval] queryDbStructureInBackgroundWithUserInfo:@{@"forceUpdate" : @YES}];
}

/**
 * Trucates the selected table(s).
 */
- (void)_truncateTable
{
	NSIndexSet *indexes = [tablesListView selectedRowIndexes];

	[indexes enumerateIndexesWithOptions:NSEnumerationReverse usingBlock:^(NSUInteger currentIndex, BOOL * _Nonnull stop) {
		[mySQLConnection queryString:[NSString stringWithFormat: @"TRUNCATE TABLE %@", [[filteredTables objectAtIndex:currentIndex] backtickQuotedString]]];

		// Couldn't truncate table
		if ([mySQLConnection queryErrored]) {
			[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error truncating table", @"error truncating table message") message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while trying to truncate the table '%@'.\n\nMySQL said: %@", @"error truncating table informative message"), [filteredTables objectAtIndex:currentIndex], [mySQLConnection lastErrorMessage]] callback:nil];
			*stop = YES;
		}

	}];

	// Ensure the the table's content view is updated to show that it has been truncated
	[tableDocumentInstance setContentRequiresReload:YES];

	[tableDataInstance resetStatusData];
}

/**
 * Adds a new table table to the database using the selected character set encoding and storage engine on a separate thread.
 *
 * This method *MUST* be called from the UI thread!
 */
- (void)_addTable
{
	NSString *tableType = [tableTypeButton title];
	NSString *tableName = [tableNameField stringValue];
	NSString *tableCharacterSet = [addTableCharsetHelper selectedCharset];
	NSString *tableColletion = [addTableCharsetHelper selectedCollation];

	NSMutableDictionary *tableDetails = [NSMutableDictionary dictionaryWithObject:tableName forKey:SPNewTableName];

	if ([tableTypeButton indexOfSelectedItem] > 0) {
		[tableDetails setObject:tableType forKey:SPNewTableType];
	}

	if (tableCharacterSet) {
		[tableDetails setObject:tableCharacterSet forKey:SPNewTableCharacterSet];
	}

	if (tableColletion) {
		[tableDetails setObject:tableColletion forKey:SPNewTableCollation];
	}

	[tableDocumentInstance startTaskWithDescription:[NSString stringWithFormat:NSLocalizedString(@"Creating %@...", @"Creating table task string"), tableName]];

	[NSThread detachNewThreadWithName:SPCtxt(@"SPTablesList table addition task", tableDocumentInstance)
							   target:self
							 selector:@selector(_addTableWithDetails:)
							   object:tableDetails];

	// Clear table name
	[[tableNameField onMainThread] setStringValue:@""];

	[tableDocumentInstance endTask];
}

/**
 * Adds a new table table to the database using the selected character set encoding and storage engine.
 */
- (void)_addTableWithDetails:(NSDictionary *)tableDetails
{
	@autoreleasepool
	{
		NSString *charSetStatement   = @"";
		NSString *collationStatement = @"";
		NSString *engineStatement    = @"";

		NSString *tableName = [tableDetails objectForKey:SPNewTableName];
		NSString *tableType = [tableDetails objectForKey:SPNewTableType];

		// Ensure the use of UTF8 when creating new tables
		BOOL changeEncoding = ![[mySQLConnection encoding] hasPrefix:@"utf8"];

		if (changeEncoding) {
			[mySQLConnection storeEncodingForRestoration];
			[mySQLConnection setEncoding:@"utf8mb4"];
		}

		// If there is an encoding selected other than the default we must specify it in CREATE TABLE statement
		NSString *encodingName = [tableDetails objectForKey:SPNewTableCharacterSet];

		if (encodingName) charSetStatement = [NSString stringWithFormat:@"DEFAULT CHARACTER SET %@", [encodingName backtickQuotedString]];

		// If there is a collation selected other than the default we must specify it in the CREATE TABLE statement
		NSString *collationName = [tableDetails objectForKey:SPNewTableCollation];

		if (collationName) collationStatement = [NSString stringWithFormat:@"DEFAULT COLLATE %@", [collationName backtickQuotedString]];

		// If there is a type selected other than the default we must specify it in CREATE TABLE statement
		if (tableType) {
			engineStatement = [NSString stringWithFormat:@"ENGINE = %@", [tableType backtickQuotedString]];
		}

		NSString *createStatement = [NSString stringWithFormat:@"CREATE TABLE %@ (id INT(11) UNSIGNED NOT NULL%@) %@ %@ %@", [tableName backtickQuotedString], [tableType isEqualToString:@"CSV"] ? @"" : @" PRIMARY KEY AUTO_INCREMENT", charSetStatement, collationStatement, engineStatement];

		// Create the table
		[mySQLConnection queryString:createStatement];

		if (![mySQLConnection queryErrored]) {

			// Table creation was successful - insert the new item into the tables list and select it.
			NSInteger addItemAtIndex = NSNotFound;
            
            [self removePinnedTablesSection];

			for (NSUInteger i = 0; i < [tables count]; i++)
			{
				NSInteger eachTableType = [[tableTypes objectAtIndex:i] integerValue];

				if (eachTableType == SPTableTypeNone) continue;
				if (eachTableType == SPTableTypeProc || eachTableType == SPTableTypeFunc) {
					addItemAtIndex = (i - 1);
					break;
				}

				if ([tableName localizedCompare:[tables objectAtIndex:i]] == NSOrderedAscending) {
					addItemAtIndex = i;
					break;
				}
			}

			if (addItemAtIndex == NSNotFound) {
				[tables addObject:tableName];
				[tableTypes addObject:[NSNumber numberWithInteger:SPTableTypeTable]];
			}
			else {
				[tables insertObject:tableName atIndex:addItemAtIndex];
				[tableTypes insertObject:[NSNumber numberWithInteger:SPTableTypeTable] atIndex:addItemAtIndex];
			}
            
            [self initPinnedTables];

			// Set the selected table name and type, and then update the filter list and the
			// selection.

			selectedTableName = [[NSString alloc] initWithString:tableName];
			selectedTableType = SPTableTypeTable;

			[[self onMainThread] updateFilter:self];
			[[tablesListView onMainThread] scrollRowToVisible:[[tablesListView onMainThread] selectedRow]];

			// Select the newly created table and switch to the table structure view for easier setup
			[tableDocumentInstance loadTable:selectedTableName ofType:selectedTableType];
			[tableDocumentInstance viewStructure];

			// Query the structure of all databases in the background (mainly for completion)
			[[tableDocumentInstance databaseStructureRetrieval] queryDbStructureInBackgroundWithUserInfo:@{@"forceUpdate" : @YES}];
		}
		else {
			// Error while creating new table

			SPMainQSync(^{
				[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error adding new table", @"error adding new table message") message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while trying to add the new table '%@'.\n\nMySQL said: %@", @"error adding new table informative message"), tableName, [self->mySQLConnection lastErrorMessage]] callback:nil];
			});

			if (changeEncoding) [mySQLConnection restoreStoredEncoding];

			[[tablesListView onMainThread] reloadData];
		}
	}
}

/**
 * Copies the currently selected object (table, view, procedure, function, etc.).
 */
- (void)_copyTable
{
	NSString *tableType = @"";
	NSString *tempTableName = nil;
	NSString *tableName = [copyTableNameField stringValue];

	if ([tableName isEqualToString:@""]) {
		[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:NSLocalizedString(@"Table must have a name.", @"message of panel when no name is given for table") callback:nil];
		return;
	}

	BOOL copyTableContent = ([copyTableContentSwitch state] == NSControlStateValueOn);

	NSString *targetDatabaseName = [chooseDatabaseButton titleOfSelectedItem];

	BOOL moveToDifferentDB = NO;

	if (![targetDatabaseName isEqualToString:mySQLConnection.database]){
		moveToDifferentDB = YES;
		tempTableName = [NSString stringWithNewUUID];
	}

	SPTableType tblType = (SPTableType)[[filteredTableTypes objectAtIndex:[tablesListView selectedRow]] integerValue];

	// Set up the table type and whether content can be duplicated.  The table type is used
	// in queries and should not be localized.
	switch (tblType){
		case SPTableTypeTable:
			tableType = @"table";
			[copyTableContentSwitch setEnabled:YES];
			break;
		case SPTableTypeView:
			tableType = @"view";
			[copyTableContentSwitch setEnabled:NO];
			break;
		case SPTableTypeProc:
			tableType = @"procedure";
			[copyTableContentSwitch setEnabled:NO];
			break;
		case SPTableTypeFunc:
			tableType = @"function";
			[copyTableContentSwitch setEnabled:NO];
			break;
		default:
			break;
	}

	// Get table/view structure
	SPMySQLResult *queryResult = [mySQLConnection queryString:[NSString stringWithFormat:@"SHOW CREATE %@ %@",
												[tableType uppercaseString],
												[[filteredTables objectAtIndex:[tablesListView selectedRow]] backtickQuotedString]
												]];
	[queryResult setReturnDataAsStrings:YES];

	if ( ![queryResult numberOfRows] ) {

		//error while getting table structure
		[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:[NSString stringWithFormat:NSLocalizedString(@"Couldn't get create syntax.\nMySQL said: %@", @"message of panel when table information cannot be retrieved"), [mySQLConnection lastErrorMessage]] callback:nil];
		return;
    }

	//insert new table name in create syntax and create new table
	NSScanner *scanner;
	NSString *scanString;

	if(tblType == SPTableTypeView){
		scanner = [[NSScanner alloc] initWithString:[[queryResult getRowAsDictionary] objectForKey:@"Create View"]];
		[scanner scanUpToString:@"AS" intoString:nil];
		[scanner scanUpToString:@"" intoString:&scanString];
		[mySQLConnection queryString:[NSString stringWithFormat:@"CREATE VIEW %@ %@", [tableName backtickQuotedString], scanString]];
	}
	else if(tblType == SPTableTypeTable){

		// check for triggers: https://dev.mysql.com/doc/refman/5.7/en/rename-table.html
		NSArray *triggers = [self->tableDataInstance triggers];

		if (moveToDifferentDB == YES && triggers.count > 0){
			[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Warning", @"warning") message:NSLocalizedString(@"Cannot duplicate a table with triggers to a different database.", @"Cannot duplicate a table with triggers to a different database") callback:nil];
			return;
		}

		scanner = [[NSScanner alloc] initWithString:[[queryResult getRowAsDictionary] objectForKey:@"Create Table"]];
		[scanner scanUpToString:@"(" intoString:nil];
		[scanner scanUpToString:@"" intoString:&scanString];

		// If there are any InnoDB referencial constraints we need to strip out the names as they must be unique.
		// MySQL will generate the new names based on the new table name.
		scanString = [scanString stringByReplacingOccurrencesOfRegex:[NSString stringWithFormat:@"CONSTRAINT `[^`]+` "] withString:@""];

		// If we're not copying the tables content as well then we need to strip out any AUTO_INCREMENT presets.
		if (!copyTableContent) {
			scanString = [scanString stringByReplacingOccurrencesOfRegex:[NSString stringWithFormat:@"AUTO_INCREMENT=[0-9]+ "] withString:@""];
		}

		NSString *queryStr =  [NSString stringWithFormat:@"CREATE TABLE %@ %@", (moveToDifferentDB == NO) ? [tableName backtickQuotedString] : [tempTableName backtickQuotedString], scanString];

		SPLog("queryStr = %@", queryStr);

		[mySQLConnection queryString:queryStr];
	}
	else if(tblType == SPTableTypeFunc || tblType == SPTableTypeProc)
	{
		// get the create syntax
		SPMySQLResult *theResult;

		if(selectedTableType == SPTableTypeProc)
			theResult = [mySQLConnection queryString:[NSString stringWithFormat:@"SHOW CREATE PROCEDURE %@", [selectedTableName backtickQuotedString]]];
		else if([self tableType] == SPTableTypeFunc)
			theResult = [mySQLConnection queryString:[NSString stringWithFormat:@"SHOW CREATE FUNCTION %@", [selectedTableName backtickQuotedString]]];
		else
			return;

		// Check for errors, only displaying if the connection hasn't been terminated
		if ([mySQLConnection queryErrored]) {
			if ([mySQLConnection isConnected]) {
				[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:[NSString stringWithFormat:NSLocalizedString(@"An error occurred while retrieving the create syntax for '%@'.\nMySQL said: %@", @"message of panel when create syntax cannot be retrieved"), selectedTableName, [mySQLConnection lastErrorMessage]] callback:nil];
			}
			return;
		}

		[theResult setReturnDataAsStrings:YES];
		NSString *tableSyntax = [[theResult getRowAsArray] objectAtIndex:2];

		// replace the old name by the new one and drop the old one
		[mySQLConnection queryString:[[tableSyntax unboxNull] stringByReplacingOccurrencesOfRegex:[NSString stringWithFormat:@"(?<=%@ )(`[^`]+?`)", [tableType uppercaseString]] withString:[tableName backtickQuotedString]]];

		if ([mySQLConnection queryErrored]) {
			[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:[NSString stringWithFormat:NSLocalizedString(@"Couldn't duplicate '%@'.\nMySQL said: %@", @"message of panel when an item cannot be renamed"), tableName, [mySQLConnection lastErrorMessage]] callback:nil];
		}

	}

	if ([mySQLConnection queryErrored]) {
		//error while creating new table
		[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Error", @"error") message:[NSString stringWithFormat:NSLocalizedString(@"Couldn't create '%@'.\nMySQL said: %@", @"message of panel when table cannot be created"), tableName, [mySQLConnection lastErrorMessage]] callback:nil];
		return;
	}

	if (copyTableContent) {
		//copy table content
		[mySQLConnection queryString:[NSString stringWithFormat:
									  @"INSERT INTO %@ SELECT * FROM %@",
									  (moveToDifferentDB == NO) ? [tableName backtickQuotedString] : [tempTableName backtickQuotedString],
									  [selectedTableName backtickQuotedString]
									  ]];

		if ([mySQLConnection queryErrored]) {
			[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Warning", @"warning") message:NSLocalizedString(@"There have been errors while copying table content. Please check the new table.", @"message of panel when table content cannot be copied") callback:nil];
		}
	}

	if (moveToDifferentDB == YES){
		SPLog(@"Copying table to new database, targetDatabaseName = %@", targetDatabaseName);
		[self _moveTable:tableName from:mySQLConnection.database to:targetDatabaseName tempTable:tempTableName];

		SPMainQSync(^{
			[self->mySQLConnection selectDatabase:targetDatabaseName];
			[self->tableDocumentInstance selectDatabase:targetDatabaseName item:nil];
			[self _renameTableOfType:SPTableTypeTableNewDB from:tempTableName to:tableName];
		});
	}
	else{
		// Insert the new item into the tables list and select it.
		NSInteger addItemAtIndex = NSNotFound;
		for (NSUInteger i = 0; i < [tables count]; i++) {
			NSInteger theTableType = [[tableTypes objectAtIndex:i] integerValue];
			if (theTableType == SPTableTypeNone) continue;
			if ((theTableType == SPTableTypeView || theTableType == SPTableTypeTable)
				&& (tblType == SPTableTypeProc || tblType == SPTableTypeFunc)) {
				continue;
			}
			if ((theTableType == SPTableTypeProc || theTableType == SPTableTypeFunc)
				&& (tblType == SPTableTypeView || tblType == SPTableTypeTable)) {
				addItemAtIndex = i - 1;
				break;
			}
			if ([tableName localizedCompare:[tables objectAtIndex:i]] == NSOrderedAscending) {
				addItemAtIndex = i;
				break;
			}
		}
		if (addItemAtIndex == NSNotFound) {
			[tables addObject:tableName];
			[tableTypes addObject:[NSNumber numberWithInteger:tblType]];
		} else {
			[tables insertObject:tableName atIndex:addItemAtIndex];
			[tableTypes insertObject:[NSNumber numberWithInteger:tblType] atIndex:addItemAtIndex];
		}

		// Set the selected table name and type, and use updateFilter to update the filter list and selection

		selectedTableName = [[NSString alloc] initWithString:tableName];
		selectedTableType = tblType;

		[self updateFilter:self];

		[tablesListView scrollRowToVisible:[tablesListView selectedRow]];
		[tableDocumentInstance loadTable:selectedTableName ofType:selectedTableType];

		// Query the structure of all databases in the background (mainly for completion)
		[[tableDocumentInstance databaseStructureRetrieval] queryDbStructureInBackgroundWithUserInfo:@{@"forceUpdate" : @YES}];
	}
}


- (void)_moveTable:(NSString *)newTableName from:(NSString *)sourceDatabaseName to:(NSString *)destinationDatabaseName tempTable:(NSString *)tempTableName{

	// check if the name really changed
	if ([sourceDatabaseName isEqualToString:destinationDatabaseName]) return;

	if(destinationDatabaseName && [destinationDatabaseName length]) {
		NSString *query = [NSString stringWithFormat: @"ALTER TABLE %@.%@ RENAME %@.%@", [sourceDatabaseName backtickQuotedString], [tempTableName backtickQuotedString], [destinationDatabaseName backtickQuotedString], [tempTableName backtickQuotedString]];

		SPLog(@"QUERY is %@", query);

		[mySQLConnection queryString:query];

		SPMainQSync(^{
			if ([self->mySQLConnection queryErrored]) {
				[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Warning", @"warning") message:NSLocalizedString(@"There have been errors while copying table content. Please check the new table.", @"message of panel when table content cannot be copied") callback:nil];

				SPLog(@"ERROR: %@", [self->mySQLConnection lastErrorMessage]);
			}
		});
	}
}

/**
 * Renames a table, view, procedure or function. Also handles only changes in case!
 * This function ONLY changes the database. It does NOT refresh the views etc.
 * CAREFUL: This function raises an exception if renaming fails, and does not show an error message.
 */
- (void)_renameTableOfType:(SPTableType)tableType from:(NSString *)oldTableName to:(NSString *)newTableName
{
	// check if the name really changed
	if ([oldTableName isEqualToString:newTableName]) return;

	// check if only the case changed - then we have to do two renames, see issue #484
	if ([[oldTableName lowercaseString] isEqualToString:[newTableName lowercaseString]])
	{
		// first try finding an unused temporary name
		// this code should be improved in case we find out that something uses table names like mytable-1, mytable-2, etc.
		NSString* tempTableName;
		int tempNumber;
		
		for (tempNumber=2; tempNumber<100; tempNumber++) 
		{
			tempTableName = [NSString stringWithFormat:@"%@-%d",selectedTableName,tempNumber];
			if ([self isTableNameValid:tempTableName forType:tableType]) break;
		}
		
		if (tempNumber==100) {
			// we couldn't find a temporary name
			[NSException raise:@"No Tempname found" format:NSLocalizedString(@"An error occurred while renaming '%@'. No temporary name could be found. Please try renaming to something else first.", @"rename table error - no temporary name found"), oldTableName];
		}

		[self _renameTableOfType:tableType from:oldTableName to:tempTableName];
		[self _renameTableOfType:tableType from:tempTableName to:newTableName];
		
		return;
	}

	//check if we are trying to rename a TABLE or a VIEW
	if (tableType == SPTableTypeView || tableType == SPTableTypeTable || tableType == SPTableTypeTableNewDB) {
		// we can use the rename table statement
		[mySQLConnection queryString:[NSString stringWithFormat:@"RENAME TABLE %@ TO %@", [oldTableName backtickQuotedString], [newTableName backtickQuotedString]]];
		// check for errors
		if ([mySQLConnection queryErrored]) {

			if(mySQLConnection.lastErrorID == 1050 && tableType == SPTableTypeTableNewDB){
				NSString *message = [NSString stringWithFormat:NSLocalizedString(@"An error occurred while renaming '%@'.\n\nMySQL said: %@", @"rename table error informative message"), oldTableName, [mySQLConnection lastErrorMessage]];

				[NSAlert createWarningAlertWithTitle:NSLocalizedString(@"Warning", @"warning") message:message callback:nil];

				return;
			}
			else{
				[NSException raise:@"MySQL Error" format:NSLocalizedString(@"An error occurred while renaming '%@'.\n\nMySQL said: %@", @"rename table error informative message"), oldTableName, [mySQLConnection lastErrorMessage]];
			}
		}

		return;
	}

	//check if we are trying to rename a PROCEDURE or a FUNCTION
	if (tableType == SPTableTypeProc || tableType == SPTableTypeFunc) {
		// procedures and functions can only be renamed if one creates a new one and deletes the old one

		// first get the create syntax
		NSString *stringTableType = @"";

		switch (tableType){
			case SPTableTypeProc: stringTableType = @"PROCEDURE"; break;
			case SPTableTypeFunc: stringTableType = @"FUNCTION"; break;
			default: break;
		}

		SPMySQLResult *theResult  = [mySQLConnection queryString:[NSString stringWithFormat:@"SHOW CREATE %@ %@", stringTableType, [oldTableName backtickQuotedString] ] ];
		if ([mySQLConnection queryErrored]) {
			[NSException raise:@"MySQL Error" format:NSLocalizedString(@"An error occurred while renaming. I couldn't retrieve the syntax for '%@'.\n\nMySQL said: %@", @"rename precedure/function error - can't retrieve syntax"), oldTableName, [mySQLConnection lastErrorMessage]];
		}
		[theResult setReturnDataAsStrings:YES];
		NSString *oldCreateSyntax = [[theResult getRowAsArray] objectAtIndex:2];

		// replace the old name with the new name
		NSRange rangeOfProcedureName = [oldCreateSyntax rangeOfString: [NSString stringWithFormat:@"%@ %@", stringTableType, [oldTableName backtickQuotedString] ] ];
		if (rangeOfProcedureName.length == 0) {
			[NSException raise:@"Unknown Syntax" format:NSLocalizedString(@"An error occurred while renaming. The CREATE syntax of '%@' could not be parsed.", @"rename error - invalid create syntax"), oldTableName];
		}
		NSString *newCreateSyntax = [oldCreateSyntax stringByReplacingCharactersInRange: rangeOfProcedureName
			withString: [NSString stringWithFormat:@"%@ %@", stringTableType, [newTableName backtickQuotedString] ] ];
		[mySQLConnection queryString: newCreateSyntax];
		if ([mySQLConnection queryErrored]) {
			[NSException raise:@"MySQL Error" format:NSLocalizedString(@"An error occurred while renaming. I couldn't recreate '%@'.\n\nMySQL said: %@", @"rename precedure/function error - can't recreate procedure"), oldTableName, [mySQLConnection lastErrorMessage]];
		}

		[mySQLConnection queryString: [NSString stringWithFormat: @"DROP %@ %@", stringTableType, [oldTableName backtickQuotedString]]];
		if ([mySQLConnection queryErrored]) {
			[NSException raise:@"MySQL Error" format:NSLocalizedString(@"An error occurred while renaming. I couldn't delete '%@'.\n\nMySQL said: %@", @"rename precedure/function error - can't delete old procedure"), oldTableName, [mySQLConnection lastErrorMessage]];
		}
		return;
	}

	[NSException raise:@"Object of unknown type" format:NSLocalizedString(@"An error occurred while renaming. '%@' is of an unknown type.", @"rename error - don't know what type the renamed thing is"), oldTableName];
}

- (NSMutableArray *)_allSchemaObjectsOfType:(SPTableType)type
{
	NSMutableArray *returnArray = [NSMutableArray array];
    NSArray *tmpTableTypes = [NSArray arrayWithArray:[self tableTypes]];
    NSUInteger tableCount = [self tables].count;

	for (NSUInteger i = 0; i < tableCount; i++)
	{
        if([[tmpTableTypes safeObjectAtIndex:i] integerValue] == type){
            [returnArray addObject:[[self tables] safeObjectAtIndex:i]];
        }
	}

	return returnArray;
}

- (BOOL)_databaseHasObjectOfType:(SPTableType)type
{
	BOOL hasObjectOfType = NO;
    NSArray *tmpTableTypes = [NSArray arrayWithArray:[self tableTypes]];
    NSUInteger tableCount = [self tables].count;

	for (NSUInteger i = 0; i < tableCount; i++)
	{
        if([[tmpTableTypes safeObjectAtIndex:i] integerValue] == type){
            hasObjectOfType = YES;
            break;
        }
	}

	return hasObjectOfType;
}

#pragma mark -

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[prefs removeObserver:self forKeyPath:SPGlobalFontSettings];
	
    NSLog(@"Dealloc called %s", __FILE_NAME__);
}

@end
