---
lab:
    title: 'Support Hybrid Transactional Analytical Processing (HTAP) with Azure Synapse Link'
    module: 'Module 9'
---

# Lab 9 - Support Hybrid Transactional Analytical Processing (HTAP) with Azure Synapse Link

In this lab, you will learn how Azure Synapse Link enables seamless connectivity of an Azure Cosmos DB account to a Synapse workspace. You will learn how to enable and configure Synapse link, then how to query the Azure Cosmos DB analytical store using Apache Spark and SQL Serverless.

After completing this lab, you will be able to:

- Configure Azure Synapse Link with Azure Cosmos DB
- Query Azure Cosmos DB with Apache Spark for Synapse Analytics
- Query Azure Cosmos DB with serverless SQL pool for Azure Synapse Analytics

## Lab setup and pre-requisites

Before starting this lab, you should complete **Lab 6: *Transform data with Azure Data Factory or Azure Synapse Pipelines***.

> **Note**: If you have ***not*** completed lab 6, but you <u>have</u> completed the lab setup for this course, you can complete these steps to create the required linked service and dataset.
>
> 1. In Synapse Studio, on the **Manage** hub, add a new **Linked service** for **Azure Cosmos DB (SQL API)** with the following settings:
>       - **Name**: asacosmosdb01
>       - **Cosmos DB account name**: asacosmosdb*xxxxxxx*
>       - **Database name**: CustomerProfile
> 2. On the **Data** hub, create the following **Integration dataset**:
>       - **Source**: Azure Cosmos DB (SQL API)
>       - **Name**: asal400_customerprofile_cosmosdb
>       - **Linked service**: asacosmosdb01
>       - **Collection**: OnlineUserProfile01
>       - **Import schema**: From connection/store

## Exercise 1 - Configuring Azure Synapse Link with Azure Cosmos DB

Tailwind Traders uses Azure Cosmos DB to store user profile data from their eCommerce site. The NoSQL document store provided by the Azure Cosmos DB SQL API provides the familiarity of managing their data using SQL syntax, while being able to read and write the files at a massive, global scale.

While Tailwind Traders is happy with the capabilities and performance of Azure Cosmos DB, they are concerned about the cost of executing a large volume of analytical queries over multiple partitions (cross-partition queries) from their data warehouse. They want to efficiently access all the data without needing to increase the Azure Cosmos DB request units (RUs). They have looked at options for extracting data from their containers to the data lake as it changes, through the Azure Cosmos DB change feed mechanism. The problem with this approach is the extra service and code dependencies and long-term maintenance of the solution. They could perform bulk exports from a Synapse Pipeline, but then they won't have the most up-to-date information at any given moment.

You decide to enable Azure Synapse Link for Cosmos DB and enable the analytical store on their Azure Cosmos DB containers. With this configuration, all transactional data is automatically stored in a fully isolated column store. This store enables large-scale analytics against the operational data in Azure Cosmos DB, without impacting the transactional workloads or incurring resource unit (RU) costs. Azure Synapse Link for Cosmos DB creates a tight integration between Azure Cosmos DB and Azure Synapse Analytics, which enables Tailwind Traders to run near real-time analytics over their operational data with no-ETL and full performance isolation from their transactional workloads.

By combining the distributed scale of Cosmos DB's transactional processing with the built-in analytical store and the computing power of Azure Synapse Analytics, Azure Synapse Link enables a Hybrid Transactional/Analytical Processing (HTAP) architecture for optimizing Tailwind Trader's business processes. This integration eliminates ETL processes, enabling business analysts, data engineers & data scientists to self-serve and run near real-time BI, analytics, and Machine Learning pipelines over operational data.

### Task 1: Enable Azure Synapse Link

1. In the Azure portal (<https://portal.azure.com>), open the resource group for your lab environment.

2. Select the **Azure Cosmos DB account**.

    ![The Azure Cosmos DB account is highlighted.](images/resource-group-cosmos.png "Azure Cosmos DB account")

3. In the left-hand menu,  select **Azure Synapse Link**.

4. Select **Enable**.

    ![Enable is highlighted.](images/synapse-link-enable.png "Azure Synapse Link")

    Before we can create an Azure Cosmos DB container with an analytical store, we must first enable Azure Synapse Link.

5. You must wait for this operation to complete before continuing, which should take about a minute. Check the status by selecting the Azure **Notifications** icon.

    ![The Enabling Synapse Link process is running.](images/notifications-running.png "Notifications")

    You will see a green checkmark next to "Enabling Synapse Link" when it successfully completes.

    ![The operation completed successfully.](images/notifications-completed.png "Notifications")

### Task 2: Create a new Azure Cosmos DB container

Tailwind Traders has an Azure Cosmos DB container named **OnlineUserProfile01**. Since we enabled the Azure Synapse Link feature _after_ the container was already created, we cannot enable the analytical store on the container. We will create a new container that has the same partition key and enable the analytical store.

After creating the container, we will create a new Synapse Pipeline to copy data from the **OnlineUserProfile01** container to the new one.

1. Select **Data Explorer** on the left-hand menu.

    ![The menu item is selected.](images/data-explorer-link.png "Data Explorer")

2. Select **New Container**.

    ![The button is highlighted.](images/new-container-button.png "New Container")

3. Create a new container with the following settings and select **OK**:
    - **Database id**: Use the existing **CustomerProfile** database.
    - **Container id**: Enter `UserProfileHTAP`
    - **Partition key**: Enter `/userId`
    - **Throughput**: Select **Autoscale**
    - **Container max RU/s**: Enter `4000`
    - **Analytical store**: On

    ![The form is configured as described.](images/new-container.png "New container")

    Here we set the **partition key** value to **userId**, because it is a field we use most often in queries and contains a relatively high cardinality (number of unique values) for good partitioning performance. We set the throughput to Autoscale with a maximum value of 4,000 request units (RUs). This means that the container will have a minimum of 400 RUs allocated (10% of the maximum number), and will scale up to a maximum of 4,000 when the scale engine detects a high enough demand to warrant increasing the throughput. Finally, we enable the **analytical store** on the container, which allows us to take full advantage of the Hybrid Transactional/Analytical Processing (HTAP) architecture from within Synapse Analytics.

    Let's take a quick look at the data we will copy over to the new container.

4. Expand the **OnlineUserProfile01** container underneath the **CustomerProfile** database, then select **Items**. Select one of the documents and view its contents. The documents are stored in JSON format.

    ![The container items are displayed.](images/existing-items.png "Container items")

5. Select **Keys** in the left-hand menu. You will need the **Primary Key** and the Cosmos DB account name (in the upper-left corner) later, so keep this tab open.

    ![The primary key is highlighted.](images/cosmos-keys.png "Keys")

### Task 3: Create and run a copy pipeline

Now that we have the new Azure Cosmos DB container with the analytical store enabled, we need to copy the contents of the existing container by using a Synapse Pipeline.

1. Open Synapse Studio (<https://web.azuresynapse.net/>) in a different tab, and then navigate to the **Integrate** hub.

    ![The Integrate menu item is highlighted.](images/integrate-hub.png "Integrate hub")

2. In the **+** menu, select **Pipeline**.

    ![The new pipeline link is highlighted.](images/new-pipeline.png "New pipeline")

3. Under **Activities**, expand the **Move & transform** group, then drag the **Copy data** activity onto the canvas. Set the **Name** to **`Copy Cosmos DB Container`** in the **Properties** blade.

    ![The new copy activity is displayed.](images/add-copy-pipeline.png "Add copy activity")

4. Select the new **Copy data** activity that you added to the canvas; and on the **Source** tab beneath the canvas, select the **asal400_customerprofile_cosmosdb** source dataset.

    ![The source is selected.](images/copy-source.png "Source")

5. Select the **Sink** tab, then select **+ New**.

    ![The sink is selected.](images/copy-sink.png "Sink")

6. Select the **Azure Cosmos DB (SQL API)** dataset type, then select **Continue**.

    ![Azure Cosmos DB is selected.](images/dataset-type.png "New dataset")

7. Set the following properties, then click **OK**:
    - **Name**: Enter `cosmos_db_htap`.
    - **Linked service**: Select **asacosmosdb01**.
    - **Collection**: Select **UserProfileHTAP**.
    - **Import schema**: Select **From connection/store** under **Import schema)**.

    ![The form is configured as described.](images/dataset-properties.png "Set properties")

8. Underneath the new sink dataset you just added, ensure that the **Insert** write behavior is selected.

    ![The sink tab is displayed.](images/sink-insert.png "Sink tab")

9. Select **Publish all**, then **Publish** to save the new pipeline.

    ![Publish all.](images/publish-all-1.png "Publish")

10. Above the pipeline canvas, select **Add trigger**, then **Trigger now**. Select **OK** to trigger the run.

    ![The trigger menu is shown.](images/pipeline-trigger.png "Trigger now")

11. Navigate to the **Monitor** hub.

    ![Monitor hub.](images/monitor-hub.png "Monitor hub")

12. Select **Pipeline runs** and wait until the pipeline run has successfully completed. You may have to select **Refresh** a few times.

    ![The pipeline run is shown as successfully completed.](images/pipeline-run-status.png "Pipeline runs")

    > This may take **around 4 minutes** to complete.

## Exercise 2 - Querying Azure Cosmos DB with Apache Spark for Synapse Analytics

Tailwind Traders wants to use Apache Spark to run analytical queries against the new Azure Cosmos DB container. In this segment, we will use built-in gestures in Synapse Studio to quickly create a Synapse Notebook that loads data from the analytical store of the HTAP-enabled container, without impacting the transactional store.

Tailwind Traders is trying to solve how they can use the list of preferred products identified with each user, coupled with any matching product IDs in their review history, to show a list of all preferred product reviews.

### Task 1: Create a notebook

1. Navigate to the **Data** hub.

    ![Data hub.](images/data-hub.png "Data hub")

2. Select the **Linked** tab and expand the **Azure Cosmos DB** section (if this is not visible, use the **&#8635;** button at the top right to refresh Synapse Studio), then expand the **asacosmosdb01 (CustomerProfile)** linked service. Right-click the **UserProfileHTAP** container, select **New notebook**, and then select **Load to DataFrame**.

    ![The new notebook gesture is highlighted.](images/new-notebook.png "New notebook")

    Notice that the **UserProfileHTAP** container that we created has a slightly different icon than the other container. This indicates that the analytical store is enabled.

3. In the new notebook, select the **SparkPool01** Spark pool in the **Attach to** dropdown list.

    ![The Attach to dropdown list is highlighted.](images/notebook-attach.png "Attach the Spark pool")

4. Select **Run all**.

    ![Thew new notebook is shown with the cell 1 output.](images/notebook-cell1.png "Cell 1")

    It will take a few minutes to start the Spark session the first time.

    In the generated code within Cell 1, notice that the **spark.read** format is set to **cosmos.olap**. This instructs Synapse Link to use the container's analytical store. If we wanted to connect to the transactional store instead, like to read from the change feed or write to the container, we'd use **cosmos.oltp** instead.

    > **Note:** You cannot write to the analytical store, only read from it. If you want to load data into the container, you need to connect to the transactional store.

    The first option configures the name of the Azure Cosmos DB linked service. The second `option` defines the Azure Cosmos DB container from which we want to read.

5. Select the **+ Code** button underneath the cell you ran. This adds a new code cell beneath the first one.

6. The DataFrame contains extra columns that we don't need. Let's remove the unwanted columns and create a clean version of the DataFrame. To do this, enter the following in the new code cell and run it:

    ```python
    unwanted_cols = {'_attachments','_etag','_rid','_self','_ts','collectionType','id'}

    # Remove unwanted columns from the columns collection
    cols = list(set(df.columns) - unwanted_cols)

    profiles = df.select(cols)

    display(profiles.limit(10))
    ```

    The output now only contains the columns that we want. Notice that the **preferredProducts** and **productReviews** columns contain child elements. Expand the values on a row to view them. You may recall seeing the raw JSON format in the **UserProfiles01** container within the Azure Cosmos DB Data Explorer.

    ![The cell's output is displayed.](images/cell2.png "Cell 2 output")

7. We should know how many records we're dealing with. To do this, enter the following in a new code cell and run it:

    ```python
    profiles.count()
    ```

    You should see a count result of 99,999.

8. We want to use the **preferredProducts** column array and **productReviews** column array for each user and create a graph of products that are from their preferred list that match with products that they have reviewed. To do this, we need to create two new DataFrames that contain flattened values from those two columns so we can join them in a later step. Enter the following in a new code cell and run it:

    ```python
    from pyspark.sql.functions import udf, explode

    preferredProductsFlat=profiles.select('userId',explode('preferredProducts').alias('productId'))
    productReviewsFlat=profiles.select('userId',explode('productReviews').alias('productReviews'))
    display(productReviewsFlat.limit(10))
    ```

    In this cell, we imported the special PySpark [explode](https://spark.apache.org/docs/latest/api/python/pyspark.sql.html?highlight=explode#pyspark.sql.functions.explode) function, which returns a new row for each element of the array. This function helps flatten the **preferredProducts** and **productReviews** columns for better readability or for easier querying.

    ![Cell output.](images/cell4.png "Cell 4 output")

    Observe the cell output where we display the **productReviewFlat** DataFrame contents. We see a new **productReviews** column that contains the **productId** we want to match to the preferred products list for the user, as well as the **reviewText** that we want to display or save.

9. Let's look at the **preferredProductsFlat** DataFrame contents. To do this, enter the following in a new cell and **run** it:

    ```python
    display(preferredProductsFlat.limit(20))
    ```

    ![Cell output.](images/cell5.png "Cell 5 results")

    Since we used the **explode** function on the preferred products array, we have flattened the column values to **userId** and **productId** rows, ordered by user.

10. Now we need to further flatten the **productReviewFlat** DataFrame contents to extract the **productReviews.productId** and **productReviews.reviewText** fields and create new rows for each data combination. To do this, enter the following in a new code cell and run it:

    ```python
    productReviews = (productReviewsFlat.select('userId','productReviews.productId','productReviews.reviewText')
        .orderBy('userId'))

    display(productReviews.limit(10))
    ```

    In the output, notice that we now have multiple rows for each `userId`.

    ![Cell output.](images/cell6.png "Cell 6 results")

11. The final step is to join the **preferredProductsFlat** and **productReviews** DataFrames on the **userId** and **productId** values to build our graph of preferred product reviews. To do this, enter the following in a new code cell and run it:

    ```python
    preferredProductReviews = (preferredProductsFlat.join(productReviews,
        (preferredProductsFlat.userId == productReviews.userId) &
        (preferredProductsFlat.productId == productReviews.productId))
    )

    display(preferredProductReviews.limit(100))
    ```

    > **Note**: You can click on the column headers in the Table view to sort the result set.

    ![Cell output.](images/cell7.png "Cell 7 results")

12. At the top right of the notebook, use the **Stop Session** button to stop the notebook session. Then close the notebook, discarding the changes.

## Exercise 3 - Querying Azure Cosmos DB with serverless SQL pool for Azure Synapse Analytics

Tailwind Traders wants to explore the Azure Cosmos DB analytical store with T-SQL. Ideally, they can create views that can then be used for joins with other analytical store containers, files from the data lake, or accessed by external tools, like Power BI.

### Task 1: Create a new SQL script

1. Navigate to the **Develop** hub.

    ![Develop hub.](images/develop-hub.png "Develop hub")

2. In the **+** menu, select **SQL script**.

    ![The SQL script button is highlighted.](images/new-script.png "SQL script")

3. When the script opens, in the **Properties** pane to the right, change the **Name** to `User Profile HTAP`. Then use the **Properties** button to close the pane.

    ![The properties pane is displayed.](images/new-script-properties.png "Properties")

4. Verify that the serverless SQL pool (**Built-in**) is selected.

    ![The serverless SQL pool is selected.](images/built-in-htap.png "Built-in")

5. Paste the following SQL query. In the OPENROWSET statement, replace **YOUR_ACCOUNT_NAME** with the Azure Cosmos DB account name and **YOUR_ACCOUNT_KEY** with the Azure Cosmos DB Primary Key from the **Keys** page in the Azure portal (which should still be open in another tab).

    ```sql
    USE master
    GO

    IF DB_ID (N'Profiles') IS NULL
    BEGIN
        CREATE DATABASE Profiles;
    END
    GO

    USE Profiles
    GO

    DROP VIEW IF EXISTS UserProfileHTAP;
    GO

    CREATE VIEW UserProfileHTAP
    AS
    SELECT
        *
    FROM OPENROWSET(
        'CosmosDB',
        N'account=YOUR_ACCOUNT_NAME;database=CustomerProfile;key=YOUR_ACCOUNT_KEY',
        UserProfileHTAP
    )
    WITH (
        userId bigint,
        cartId varchar(50),
        preferredProducts varchar(max),
        productReviews varchar(max)
    ) AS profiles
    CROSS APPLY OPENJSON (productReviews)
    WITH (
        productId bigint,
        reviewText varchar(1000)
    ) AS reviews
    GO
    ```

6. Use the **Run** button to run the query, which:
    - Creates a new serverless SQL pool database named **Profiles** if it does not exist
    - Changes the database context to the **Profiles** database.
    - Drops the **UserProfileHTAP** view if it exists.
    - Creates a SQL view named **UserProfileHTAP**.
    - Uses the OPENROWSET statement to set the data source type to **CosmosDB**, sets the account details, and specifies that we want to create the view over the Azure Cosmos DB analytical store container named **UserProfileHTAP**.
    - Matches the property names in the JSON documents and applies the appropriate SQL data types. Notice that we set the **preferredProducts** and **productReviews** fields to **varchar(max)**. This is because both of these properties contain JSON-formatted data within.
    - Since the **productReviews** property in the JSON documents contain nested subarrays, the script needs to "join" the properties from the document with all elements of the array. Synapse SQL enables us to flatten the nested structure by applying the OPENJSON function on the nested array. We flatten the values within **productReviews** like we did using the Python **explode** function earlier in the Synapse Notebook.

7. Navigate to the **Data** hub.

    ![Data hub.](images/data-hub.png "Data hub")

8. Select the **Workspace** tab and expand the **SQL database** group. Expand the **Profiles** SQL on-demand database (if you do not see this on the list, refresh the **Databases** list). Expand **Views**, then right-click the **UserProfileHTA** view, select **New SQL script**, and then **Select TOP 100 rows**.

    ![The select top 100 rows query option is highlighted.](images/new-select-query.png "New select query")

9. Ensure the script is connected to the **Built-in** SQL pool, then run the query and view the results.

    ![The view results are displayed.](images/select-htap-view.png "Select HTAP view")

    The **preferredProducts** and **productReviews** fields are included in the view, which both contain JSON-formatted values. Notice how the CROSS APPLY OPENJSON statement in the view successfully flattened the nested subarray values in the **productReviews** field by extracting the **productId** and **reviewText** values into new fields.
