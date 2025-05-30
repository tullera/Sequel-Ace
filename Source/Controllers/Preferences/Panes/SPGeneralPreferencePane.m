//
//  SPGeneralPreferencePane.m
//  sequel-pro
//
//  Created by Stuart Connolly (stuconnolly.com) on October 29, 2010.
//  Copyright (c) 2010 Stuart Connolly. All rights reserved.
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

#import "SPGeneralPreferencePane.h"
#import "SPPreferenceController.h"
#import "SPFavoritesController.h"
#import "SPTreeNode.h"
#import "SPFavoriteNode.h"
#import "SPGroupNode.h"

#import "sequel-ace-Swift.h"

static NSString *SPDatabaseImage = @"database-small";

@interface SPGeneralPreferencePane ()

- (NSArray *)_constructMenuItemsForNode:(SPTreeNode *)node atLevel:(NSUInteger)level;

@end

@implementation SPGeneralPreferencePane

#pragma mark -
#pragma mark Initialisation

- (void)awakeFromNib
{
    [super awakeFromNib];
    
	// Generic folder image for use in the outline view's groups
	folderImage = [[NSWorkspace sharedWorkspace] iconForFileType:NSFileTypeForHFSTypeCode(kGenericFolderIcon)];
	
	[folderImage setSize:NSMakeSize(16, 16)];
}

#pragma mark -
#pragma mark IB action methods

/**
 * Updates the default favorite.
 */ 
- (IBAction)updateDefaultFavorite:(NSPopUpButton *)sender
{		
	for (NSMenuItem *item in [defaultFavoritePopup itemArray])
	{
		[item setState:NSControlStateValueOff];
	}
	
	[sender setState:NSControlStateValueOn];
	[defaultFavoritePopup setTitle:[sender title]];
	
	[prefs setBool:([defaultFavoritePopup indexOfSelectedItem] == 0) forKey:SPSelectLastFavoriteUsed];
			
	[prefs setInteger:[sender tag] forKey:SPDefaultFavorite];
}

- (IBAction)showGlobalResultFontPanel:(id)sender {
	[(SPPreferenceController *)[[[self view] window] delegate] setFontChangeTarget:SPPrefFontChangeTargetGeneral];

	[[NSFontManager sharedFontManager] setAction:@selector(changeDefaultFont:)];

	NSFontPanel *panel = [[NSFontManager sharedFontManager] fontPanel:YES];
	[panel setPanelFont:[NSUserDefaults getFont] isMultiple:NO];
	
	// Create an accessory view with a system font button
	NSView *accessoryView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 30)];
	NSButton *systemFontButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 5, 180, 20)];
	[systemFontButton setTitle:NSLocalizedString(@"Use System Font", @"System Font button in font panel")];
	[systemFontButton setBezelStyle:NSBezelStyleRounded];
	[systemFontButton setTarget:self];
	[systemFontButton setAction:@selector(changeDefaultFont:)];
	[systemFontButton setTag:1001];
	[accessoryView addSubview:systemFontButton];
	
	[panel setAccessoryView:accessoryView];
	[panel makeKeyAndOrderFront:self];
}

- (void)changeDefaultFont:(id)sender {
	if ([sender isKindOfClass:[NSControl class]] && [sender tag] == 1001) {
		NSFont *systemFont = [NSUserDefaults getSystemFont];
		[NSUserDefaults saveFont:systemFont];
		
		// Update the font panel to show the system font
		NSFontPanel *panel = [[NSFontManager sharedFontManager] fontPanel:NO];
		if (panel) {
			[panel setPanelFont:systemFont isMultiple:NO];
		}
	}

    [(SPPreferenceController *)[[[self view] window] delegate] changeDefaultFont:nil];
}

#pragma mark -
#pragma mark Public API

/**
 * Updates the displayed font according to the user's preferences.
 */
- (void)updateDisplayedFontName {
	[globalResultFontName setFont:[NSUserDefaults getFont]];
}

/**
 * (Re)builds the default favorite popup button.
 */
- (void)updateDefaultFavoritePopup
{
	[defaultFavoritePopup removeAllItems];
	
	[defaultFavoritePopup addItemWithTitle:NSLocalizedString(@"Last Used", @"Last Used entry in favorites menu")];
	[[defaultFavoritePopup menu] addItem:[NSMenuItem separatorItem]];
	
	NSArray *favorites = [[[[[SPFavoritesController sharedFavoritesController] favoritesTree] childNodes] objectAtIndex:0] childNodes];
	
	if ([favorites count] > 0) {
		
		// Add all favorites to the menu
		for (SPTreeNode *node in favorites)
		{
			NSArray *items = [self _constructMenuItemsForNode:node atLevel:0];
			
			for (NSMenuItem *item in items)
			{
				[[defaultFavoritePopup menu] addItem:item];
			}
		}
	}
	else {
		[defaultFavoritePopup addItemWithTitle:NSLocalizedString(@"No Favorties", @"No favorites entry in favorites menu")]; 
		
		[[defaultFavoritePopup itemAtIndex:2] setEnabled:NO];
	}
	
	// Select the default favorite from prefs	
	[defaultFavoritePopup selectItemWithTag:[prefs boolForKey:SPSelectLastFavoriteUsed] ? 0 : [prefs integerForKey:SPDefaultFavorite]];
}

#pragma mark -
#pragma mark Private API

/**
 * Builds a menu item and sub-menu (if required) of the supplied tree node.
 *
 * @param node The node to build the menu item for
 *
 * @return The menu item
 */
- (NSArray *)_constructMenuItemsForNode:(SPTreeNode *)node atLevel:(NSUInteger)level
{	
	NSMutableArray *items = [NSMutableArray array];
	
	if ([node isGroup]) {
		
		level++;
		
		SPGroupNode *groupNode = (SPGroupNode *)[node representedObject];
		
		NSMenuItem *groupItem = [[NSMenuItem alloc] initWithTitle:[groupNode nodeName] action:NULL keyEquivalent:@""];
		
		NSUInteger groupLevel = level - 1;
		
		[groupItem setEnabled:NO];
		[groupItem setImage:folderImage];
		[groupItem setIndentationLevel:groupLevel];
		
		[items addObject:groupItem];
		
		for (SPTreeNode *childNode in [node childNodes])
		{
			NSArray *innerItems = [self _constructMenuItemsForNode:childNode atLevel:level];
	
			[items addObjectsFromArray:innerItems];
		}
	}
	else {
		NSDictionary *favorite = [(SPFavoriteNode *)[node representedObject] nodeFavorite];
		
		NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:[favorite objectForKey:SPFavoriteNameKey] action:@selector(updateDefaultFavorite:) keyEquivalent:@""];
	
		[menuItem setTag:[[favorite objectForKey:SPFavoriteIDKey] integerValue]];
		[menuItem setImage:[NSImage imageNamed:SPDatabaseImage]];
		[menuItem setIndentationLevel:level];
		[menuItem setTarget:self];
		
		[items addObject:menuItem];
	}
	
	return items;
}

#pragma mark -
#pragma mark Preference pane protocol methods

- (NSView *)preferencePaneView
{
	return [self view];
}

- (NSImage *)preferencePaneIcon
{
	if (@available(macOS 11.0, *)) {
		return [NSImage imageWithSystemSymbolName:@"gear" accessibilityDescription:nil];
	} else {
		return [NSImage imageNamed:NSImageNamePreferencesGeneral];
	}
}

- (NSString *)preferencePaneName
{
	return NSLocalizedString(@"General", @"general preference pane name");
}

- (NSString *)preferencePaneIdentifier
{
	return SPPreferenceToolbarGeneral;
}

- (NSString *)preferencePaneToolTip
{
	return NSLocalizedString(@"General Preferences", @"general preference pane tooltip");
}

- (void)preferencePaneWillBeShown
{
	[self updateDisplayedFontName];
	[self updateDefaultFavoritePopup];
}

@end
